#!/usr/bin/env python3
"""Measure Mail.app-backed V1 workflows without persisting mail data.

The process keeps opaque account/message references in memory only. Output is
aggregate timing/count data so it is safe to save as a benchmark artifact.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
from typing import Any, Callable


class MCPProcess:
    def __init__(self, executable: str) -> None:
        self.process = subprocess.Popen(
            [executable, "serve", "--transport", "stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any], timeout: float) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(
            json.dumps(
                {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            )
            + "\n"
        )
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = max(0.01, deadline - time.monotonic())
            ready, _, _ = select.select([self.process.stdout], [], [], min(0.2, remaining))
            if not ready:
                continue
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("stdio backend exited before responding")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response
        raise TimeoutError(f"request timed out: {method}")

    def call_tool(self, name: str, arguments: dict[str, Any], timeout: float) -> Any:
        response = self.request(
            "tools/call",
            {"name": name, "arguments": arguments},
            timeout,
        )
        result = response.get("result", {})
        content = result.get("content", [])
        if not content or content[0].get("type") != "text":
            raise RuntimeError("MCP tool returned no structured text result")
        envelope = json.loads(content[0]["text"])
        if not envelope.get("success"):
            error = envelope.get("error", {})
            raise ToolFailure(str(error.get("code", "unknown")))
        return envelope.get("data")

    def close(self) -> None:
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


class ToolFailure(Exception):
    pass


def items(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        for key in ("items", "accounts", "mailboxes", "messages"):
            candidate = value.get(key)
            if isinstance(candidate, list):
                return [item for item in candidate if isinstance(item, dict)]
    return []


def run_workflow(
    name: str,
    operation: Callable[[], Any],
) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        value = operation()
        count = len(items(value))
        if isinstance(value, dict) and not count and "summary" in value:
            count = 1
        return {
            "workflow": name,
            "status": "ok",
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "result_count": count,
        }
    except TimeoutError:
        return {
            "workflow": name,
            "status": "timeout",
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "result_count": 0,
        }
    except ToolFailure as error:
        return {
            "workflow": name,
            "status": "tool_error",
            "error_code": str(error),
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "result_count": 0,
        }
    except Exception as error:  # noqa: BLE001 - diagnostic output is normalized below
        return {
            "workflow": name,
            "status": "error",
            "error_type": type(error).__name__,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "result_count": 0,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/apple-platform-mcp")
    parser.add_argument("--request-timeout", type=float, default=15.0)
    args = parser.parse_args()

    backend = MCPProcess(os.path.abspath(args.binary))
    try:
        backend.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "mail-workflow-benchmark", "version": "1"},
            },
            args.request_timeout,
        )
        assert backend.process.stdin is not None
        backend.process.stdin.write(
            json.dumps(
                {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
            )
            + "\n"
        )
        backend.process.stdin.flush()

        accounts: list[dict[str, Any]] = []
        mailboxes: list[dict[str, Any]] = []
        newest: list[dict[str, Any]] = []
        sender_query = "nonexistent@example.invalid"
        subject_query = "__no_matching_subject__"
        message_id: str | None = None
        rows: list[dict[str, Any]] = []

        account_data: Any = None
        rows.append(
            run_workflow(
                "list_accounts",
                lambda: backend.call_tool("mail_list_accounts", {}, args.request_timeout),
            )
        )
        account_data = backend.call_tool("mail_list_accounts", {}, args.request_timeout)
        accounts = items(account_data)
        account_id = accounts[0].get("id") if accounts else None

        if account_id:
            rows.append(
                run_workflow(
                    "list_mailboxes",
                    lambda: backend.call_tool(
                        "mail_list_mailboxes",
                        {"account_id": account_id},
                        args.request_timeout,
                    ),
                )
            )
            mailbox_data = backend.call_tool(
                "mail_list_mailboxes", {"account_id": account_id}, args.request_timeout
            )
            mailboxes = items(mailbox_data)

        rows.append(
            run_workflow(
                "newest_10_inbox",
                lambda: backend.call_tool(
                    "mail_search_messages", {"limit": 10}, args.request_timeout
                ),
            )
        )
        newest_data = backend.call_tool(
            "mail_search_messages", {"limit": 10}, args.request_timeout
        )
        newest = items(newest_data)
        if newest:
            message_id = newest[0].get("id")
            sender = newest[0].get("sender")
            if isinstance(sender, dict) and isinstance(sender.get("address"), str):
                sender_query = sender["address"]
            if isinstance(newest[0].get("subject"), str) and newest[0]["subject"]:
                subject_query = newest[0]["subject"]

        rows.append(
            run_workflow(
                "unread_10_inbox",
                lambda: backend.call_tool(
                    "mail_search_messages",
                    {"limit": 10, "unread_only": True},
                    args.request_timeout,
                ),
            )
        )
        rows.append(
            run_workflow(
                "sender_search_inbox",
                lambda: backend.call_tool(
                    "mail_search_messages",
                    {"from": sender_query, "limit": 10},
                    args.request_timeout,
                ),
            )
        )
        rows.append(
            run_workflow(
                "subject_search_inbox",
                lambda: backend.call_tool(
                    "mail_search_messages",
                    {"subject": subject_query, "limit": 10},
                    args.request_timeout,
                ),
            )
        )
        if message_id:
            rows.append(
                run_workflow(
                    "get_metadata_only",
                    lambda: backend.call_tool(
                        "mail_get_message",
                        {
                            "message_id": message_id,
                            "include_body": False,
                            "include_attachment_metadata": False,
                        },
                        args.request_timeout,
                    ),
                )
            )
            rows.append(
                run_workflow(
                    "get_message_body",
                    lambda: backend.call_tool(
                        "mail_get_message",
                        {
                            "message_id": message_id,
                            "include_body": True,
                            "body_format": "plain_text",
                            "max_body_bytes": 16_384,
                            "include_attachment_metadata": False,
                        },
                        args.request_timeout,
                    ),
                )
            )
        else:
            rows.extend(
                {
                    "workflow": workflow,
                    "status": "no_message_available",
                    "duration_ms": 0.0,
                    "result_count": 0,
                }
                for workflow in ("get_metadata_only", "get_message_body")
            )

        rows.append(
            run_workflow(
                "broad_archive_search",
                lambda: backend.call_tool(
                    "mail_search_messages",
                    {"scope": "all", "limit": 10},
                    args.request_timeout,
                ),
            )
        )
        print(
            json.dumps(
                {
                    "fixture": "local_mail_app_nonpersistent",
                    "privacy": "aggregate_timings_and_counts_only",
                    "request_timeout_seconds": args.request_timeout,
                    "workflows": rows,
                },
                sort_keys=True,
            )
        )
        return 0 if all(row["status"] in ("ok", "no_message_available") for row in rows) else 2
    finally:
        backend.close()


if __name__ == "__main__":
    sys.exit(main())
