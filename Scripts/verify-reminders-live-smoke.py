#!/usr/bin/env python3
"""Run an explicitly authorized, isolated Reminders MCP live smoke test.

This runner is intentionally opt-in. It can list writable source-list choices
without mutations, but it will create data only with both ``--confirm-live``
and an explicitly supplied opaque ``--source-list-id``. It creates only a
fresh, run-scoped list and reminder, then cleans up those exact references.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
import uuid
from typing import Any


REMINDER_TOOL_NAMES = frozenset(
    {
        "reminder_list_lists",
        "reminder_list_reminders",
        "reminder_get_reminder",
        "reminder_create_reminder",
        "reminder_update_reminder",
        "reminder_complete_reminder",
        "reminder_delete_reminder",
        "reminder_create_list",
        "reminder_update_list",
        "reminder_delete_list",
    }
)


class ToolFailure(RuntimeError):
    """A normalized MCP tool error whose code is safe to report."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class MCPProcess:
    def __init__(self, binary: str, config: str, timeout: float) -> None:
        self.timeout = timeout
        self.next_id = 1
        self.process = subprocess.Popen(
            [binary, "serve", "--transport", "stdio", "--config", config],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )

    def __enter__(self) -> MCPProcess:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def start(self) -> None:
        initialized = self.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "reminders-live-smoke", "version": "1"},
            },
        )
        if initialized.get("result", {}).get("protocolVersion") != "2025-06-18":
            raise RuntimeError("unexpected_protocol")
        self.notify("notifications/initialized", {})
        discovered = self.request("tools/list", {})
        tool_names = {
            item.get("name")
            for item in discovered.get("result", {}).get("tools", [])
            if isinstance(item, dict)
        }
        if not REMINDER_TOOL_NAMES.issubset(tool_names):
            raise RuntimeError("reminder_tool_discovery_failed")

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        assert self.process.stdout is not None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            remaining = max(0.01, deadline - time.monotonic())
            ready, _, _ = select.select([self.process.stdout], [], [], min(0.2, remaining))
            if not ready:
                continue
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("stdio_backend_exited")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response
        raise TimeoutError("mcp_request_timeout")

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        result = response.get("result", {})
        content = result.get("content", [])
        if not isinstance(content, list) or not content:
            raise RuntimeError("mcp_tool_response_missing_content")
        first = content[0]
        if not isinstance(first, dict) or first.get("type") != "text":
            raise RuntimeError("mcp_tool_response_not_text")
        envelope = json.loads(first.get("text", "{}"))
        if envelope.get("success") is not True:
            error = envelope.get("error", {})
            code = error.get("code") if isinstance(error, dict) else None
            raise ToolFailure(str(code or "unknown"))
        return envelope.get("data")

    def close(self) -> None:
        if self.process.poll() is not None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def _write(self, payload: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise RuntimeError("stdio_backend_exited")
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()


def object_value(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RuntimeError("unexpected_mcp_data_shape")
    return value


def list_value(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise RuntimeError("unexpected_mcp_data_shape")
    return value


def opaque_id(value: Any) -> str:
    item = object_value(value)
    identifier = item.get("id")
    if not isinstance(identifier, str) or not identifier.startswith("rr1_"):
        raise RuntimeError("unexpected_opaque_reference")
    return identifier


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise RuntimeError(reason)


def writable_sources(lists: list[dict[str, Any]]) -> list[dict[str, str | None]]:
    sources: list[dict[str, str | None]] = []
    for item in lists:
        identifier = item.get("id")
        name = item.get("name")
        capabilities = item.get("capabilities")
        if (
            not isinstance(identifier, str)
            or not isinstance(name, str)
            or not isinstance(capabilities, dict)
            or capabilities.get("can_write") is not True
        ):
            continue
        source_name = item.get("source_name")
        sources.append(
            {
                "id": identifier,
                "name": name,
                "source_name": source_name if isinstance(source_name, str) else None,
            }
        )
    return sources


def verify_write_policy(info: Any) -> None:
    values = object_value(info)
    require(values.get("reminder_mutation_mode") == "allowed", "reminder_writes_not_allowed")
    require(values.get("reminder_list_delete_enabled") is True, "reminder_list_delete_not_allowed")


def selected_source(lists: list[dict[str, Any]], source_list_id: str) -> None:
    matching = [item for item in writable_sources(lists) if item["id"] == source_list_id]
    require(len(matching) == 1, "explicit_writable_source_not_found")


def expect_missing_reminder(process: MCPProcess, reminder_id: str) -> None:
    try:
        process.call_tool("reminder_get_reminder", {"reminder_id": reminder_id})
    except ToolFailure as error:
        require(error.code == "reminderNotFound", "unexpected_post_delete_error")
        return
    raise RuntimeError("deleted_reminder_still_resolves")


def cleanup(
    binary: str,
    config: str,
    timeout: float,
    run_id: str,
    reminder_id: str | None,
    list_id: str | None,
) -> dict[str, str]:
    if reminder_id is None and list_id is None:
        return {"status": "not_needed"}

    outcome: dict[str, str] = {}
    try:
        with MCPProcess(binary, config, timeout) as process:
            process.start()
            if reminder_id is not None:
                try:
                    process.call_tool(
                        "reminder_delete_reminder",
                        {
                            "reminder_id": reminder_id,
                            "idempotency_key": f"{run_id}:cleanup-reminder",
                        },
                    )
                    outcome["reminder"] = "deleted"
                except ToolFailure as error:
                    outcome["reminder"] = (
                        "already_absent" if error.code == "reminderNotFound" else "not_deleted"
                    )
            if list_id is not None:
                try:
                    process.call_tool(
                        "reminder_delete_list",
                        {
                            "list_id": list_id,
                            "idempotency_key": f"{run_id}:cleanup-list",
                        },
                    )
                    outcome["list"] = "deleted"
                except ToolFailure as error:
                    outcome["list"] = (
                        "already_absent" if error.code == "reminderListNotFound" else "not_deleted"
                    )
    except Exception:  # noqa: BLE001 - never expose backend diagnostics from cleanup
        outcome["status"] = "cleanup_backend_unavailable"
        return outcome

    outcome["status"] = "complete" if all(value != "not_deleted" for value in outcome.values()) else "incomplete"
    return outcome


def list_sources(binary: str, config: str, timeout: float) -> int:
    with MCPProcess(binary, config, timeout) as process:
        process.start()
        candidates = writable_sources(list_value(process.call_tool("reminder_list_lists", {})))
    print(json.dumps({"status": "ready", "writable_sources": candidates}, sort_keys=True))
    return 0 if candidates else 2


def run_live_smoke(
    binary: str,
    config: str,
    timeout: float,
    source_list_id: str,
    run_id: str,
) -> int:
    created_list_id: str | None = None
    created_reminder_id: str | None = None
    stages: list[str] = []
    list_name = f"Apple Platform MCP Smoke Test {run_id}"
    renamed_list_name = f"Apple Platform MCP Smoke Test Renamed {run_id}"
    reminder_title = f"Apple Platform MCP Smoke Reminder {run_id}"
    updated_reminder_title = f"Apple Platform MCP Smoke Reminder Updated {run_id}"

    try:
        with MCPProcess(binary, config, timeout) as first_process:
            first_process.start()
            verify_write_policy(first_process.call_tool("mail_server_info", {}))
            source_lists = list_value(first_process.call_tool("reminder_list_lists", {}))
            selected_source(source_lists, source_list_id)
            stages.append("permission_policy_and_source")

            create_list_arguments = {
                "source_list_id": source_list_id,
                "name": list_name,
                "idempotency_key": f"{run_id}:create-list",
            }
            created_list = first_process.call_tool("reminder_create_list", create_list_arguments)
            created_list_id = opaque_id(created_list)
            create_list_retry = first_process.call_tool("reminder_create_list", create_list_arguments)
            require(opaque_id(create_list_retry) == created_list_id, "list_idempotency_failed")
            stages.append("create_list_and_idempotency")

            updated_list = first_process.call_tool(
                "reminder_update_list",
                {
                    "list_id": created_list_id,
                    "name": renamed_list_name,
                    "idempotency_key": f"{run_id}:update-list",
                },
            )
            require(opaque_id(updated_list) == created_list_id, "list_reference_changed_after_update")
            stages.append("update_list")

            create_reminder_arguments = {
                "list_id": created_list_id,
                "title": reminder_title,
                "notes": "Created only by the Apple Platform MCP isolated live smoke test.",
                "priority": 5,
                "idempotency_key": f"{run_id}:create-reminder",
            }
            created_reminder = first_process.call_tool(
                "reminder_create_reminder", create_reminder_arguments
            )
            created_reminder_id = opaque_id(created_reminder)
            create_reminder_retry = first_process.call_tool(
                "reminder_create_reminder", create_reminder_arguments
            )
            require(opaque_id(create_reminder_retry) == created_reminder_id, "reminder_idempotency_failed")
            stages.append("create_reminder_and_idempotency")

            fetched = object_value(
                first_process.call_tool(
                    "reminder_get_reminder", {"reminder_id": created_reminder_id}
                )
            )
            require(fetched.get("id") == created_reminder_id, "reference_unstable_after_save")
            reminders = list_value(
                first_process.call_tool(
                    "reminder_list_reminders",
                    {"list_id": created_list_id, "completed": False, "limit": 20},
                )
            )
            require(
                any(item.get("id") == created_reminder_id for item in reminders),
                "created_reminder_missing_from_list",
            )
            stages.append("read_after_create")

        with MCPProcess(binary, config, timeout) as second_process:
            second_process.start()
            restart_lists = list_value(second_process.call_tool("reminder_list_lists", {}))
            require(
                any(item.get("id") == created_list_id for item in restart_lists),
                "list_reference_unstable_after_restart",
            )
            restart_reminders = list_value(
                second_process.call_tool(
                    "reminder_list_reminders", {"list_id": created_list_id, "limit": 20}
                )
            )
            require(
                any(item.get("id") == created_reminder_id for item in restart_reminders),
                "reminder_reference_unstable_after_restart",
            )
            restarted = object_value(
                second_process.call_tool(
                    "reminder_get_reminder", {"reminder_id": created_reminder_id}
                )
            )
            require(restarted.get("id") == created_reminder_id, "restart_get_reference_mismatch")
            stages.append("reference_stability_after_restart")

            updated_reminder = object_value(
                second_process.call_tool(
                    "reminder_update_reminder",
                    {
                        "reminder_id": created_reminder_id,
                        "title": updated_reminder_title,
                        "notes": None,
                        "priority": 9,
                        "idempotency_key": f"{run_id}:update-reminder",
                    },
                )
            )
            require(updated_reminder.get("id") == created_reminder_id, "reference_changed_after_update")
            reread = object_value(
                second_process.call_tool(
                    "reminder_get_reminder", {"reminder_id": created_reminder_id}
                )
            )
            require(reread.get("title") == updated_reminder_title, "updated_title_not_visible")
            require(
                reread.get("notes") is None,
                "updated_notes_not_cleared",
            )
            stages.append("update_reminder")

            completed = object_value(
                second_process.call_tool(
                    "reminder_complete_reminder",
                    {
                        "reminder_id": created_reminder_id,
                        "idempotency_key": f"{run_id}:complete-reminder",
                    },
                )
            )
            require(
                completed.get("id") == created_reminder_id and completed.get("completed") is True,
                "completion_not_visible_through_original_reference",
            )
            stages.append("complete_reminder")

            deleted = object_value(
                second_process.call_tool(
                    "reminder_delete_reminder",
                    {
                        "reminder_id": created_reminder_id,
                        "idempotency_key": f"{run_id}:delete-reminder",
                    },
                )
            )
            require(deleted.get("deleted") is True, "reminder_delete_not_confirmed")
            expect_missing_reminder(second_process, created_reminder_id)
            remaining = list_value(
                second_process.call_tool(
                    "reminder_list_reminders", {"list_id": created_list_id, "limit": 20}
                )
            )
            require(
                all(item.get("id") != created_reminder_id for item in remaining),
                "deleted_reminder_still_listed",
            )
            stages.append("delete_reminder")

            deleted_list = object_value(
                second_process.call_tool(
                    "reminder_delete_list",
                    {
                        "list_id": created_list_id,
                        "idempotency_key": f"{run_id}:delete-list",
                    },
                )
            )
            require(
                deleted_list.get("deleted") is True and deleted_list.get("reminder_count") == 0,
                "list_delete_not_confirmed",
            )
            final_lists = list_value(second_process.call_tool("reminder_list_lists", {}))
            require(
                all(item.get("id") != created_list_id for item in final_lists),
                "deleted_list_still_listed",
            )
            stages.append("delete_list_and_cleanup")

        print(
            json.dumps(
                {
                    "status": "passed",
                    "run_id": run_id,
                    "stages": stages,
                    "references_stable_after_save_update_restart": True,
                    "cleanup": "complete",
                },
                sort_keys=True,
            )
        )
        return 0
    except Exception as error:  # noqa: BLE001 - normalized report intentionally hides data
        cleanup_result = cleanup(
            binary,
            config,
            timeout,
            run_id,
            created_reminder_id,
            created_list_id,
        )
        report: dict[str, Any] = {
            "status": "failed",
            "run_id": run_id,
            "stages": stages,
            "error_type": type(error).__name__,
            "cleanup": cleanup_result,
        }
        if isinstance(error, ToolFailure):
            report["error_code"] = error.code
        elif isinstance(error, RuntimeError):
            reason = str(error)
            if reason and len(reason) <= 100 and all(
                character.isalnum() or character == "_" for character in reason
            ):
                report["error_reason"] = reason
        print(json.dumps(report, sort_keys=True))
        return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, help="App-bundle executable to launch.")
    parser.add_argument("--config", required=True, help="Absolute temporary server configuration path.")
    parser.add_argument("--source-list-id", help="Explicit opaque writable source-list reference.")
    parser.add_argument("--list-writable-sources", action="store_true")
    parser.add_argument("--confirm-live", action="store_true")
    parser.add_argument("--run-id")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    binary = os.path.abspath(args.binary)
    config = os.path.abspath(args.config)
    if not os.path.isfile(binary):
        parser.error("--binary must point to an executable file")
    if not os.path.isfile(config) or not os.path.isabs(args.config):
        parser.error("--config must be an existing absolute file")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    if args.list_writable_sources:
        if args.confirm_live or args.source_list_id:
            parser.error("--list-writable-sources cannot be combined with live mutation arguments")
        return list_sources(binary, config, args.timeout)

    if not args.confirm_live or not args.source_list_id:
        parser.error("live mutations require --confirm-live and --source-list-id")
    run_id = args.run_id or f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{uuid.uuid4().hex[:10]}"
    if not all(character.isalnum() or character in "-_" for character in run_id):
        parser.error("--run-id may contain only letters, digits, hyphens, and underscores")
    return run_live_smoke(binary, config, args.timeout, args.source_list_id, run_id)


if __name__ == "__main__":
    raise SystemExit(main())
