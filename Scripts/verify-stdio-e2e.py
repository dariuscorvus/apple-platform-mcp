#!/usr/bin/env python3
"""Verify the external newline-delimited stdio MCP handshake."""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
from typing import Any


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=".build/debug/apple-platform-mcp")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    process = subprocess.Popen(
        [os.path.abspath(args.binary), "serve", "--transport", "stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    def send(message: dict[str, Any]) -> None:
        assert process.stdin is not None
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def read_response(request_id: int) -> dict[str, Any]:
        assert process.stdout is not None
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], 0.2)
            if not ready:
                continue
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("stdio process exited before responding")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response
        raise TimeoutError(f"timeout waiting for response id {request_id}")

    try:
        initialize = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "stdio-e2e", "version": "1"},
            },
        }
        send(initialize)
        initialize_response = read_response(1)
        send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools_response = read_response(2)

        initialize_result = initialize_response.get("result", {})
        tool_names = [
            item.get("name")
            for item in tools_response.get("result", {}).get("tools", [])
        ]
        expected = {
            "mail_server_info",
            "mail_list_accounts",
            "mail_list_mailboxes",
            "mail_search_messages",
            "mail_get_message",
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
            "mail_send_message",
            "mail_create_draft",
            "mail_move_message",
            "mail_archive_message",
            "mail_trash_message",
            "mail_update_message",
        }
        if initialize_result.get("protocolVersion") != "2025-06-18":
            raise RuntimeError("initialize returned an unexpected protocol version")
        if set(tool_names) != expected:
            raise RuntimeError("tools/list returned an unexpected tool set")
        print(json.dumps({
            "initialize": "ok",
            "protocol": initialize_result["protocolVersion"],
            "tools": tool_names,
            "private_data_emitted": False,
        }, sort_keys=True))
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # noqa: BLE001 - safe diagnostic surface
        print(json.dumps({"status": "failed", "error_type": type(error).__name__}))
        raise
