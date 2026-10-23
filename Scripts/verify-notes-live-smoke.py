#!/usr/bin/env python3
"""Opt-in Notes acceptance test; never edits/deletes existing notes.

Writes only to an explicitly supplied folder reference. A private on-disk journal
prevents this runner from silently issuing a fresh create after an interrupted
attempt or process restart. It is an operator aid, not a server idempotency store.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import urllib.parse
import urllib.request
import uuid

_spec = importlib.util.spec_from_file_location(
    "reminders_smoke", Path(__file__).with_name("verify-reminders-live-smoke.py")
)
assert _spec and _spec.loader
_existing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_existing)
MCPProcess = _existing.MCPProcess
ToolFailure = _existing.ToolFailure
TOOLS = {"notes_list_accounts", "notes_list_folders", "notes_search_notes", "notes_get_note", "notes_create_note"}
TEXT = 'Synthetischer MCP-Test: äöü ÄÖÜ ß\nZweite Zeile: <tag> & "Anführungszeichen"\nKeine persönlichen Daten.'


def require(condition: bool, code: str) -> None:
    if not condition:
        raise RuntimeError(code)


def write_private(path: Path, value: dict, *, create_only: bool = False) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.is_absolute() and path.parent.stat().st_mode & 0o077 == 0, "private_absolute_journal_directory_required")
    fd, name = tempfile.mkstemp(prefix=".notes-smoke-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        if create_only:
            os.link(name, path)  # Atomic reservation: concurrent runners cannot share a journal.
        else:
            os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class HTTPClient:
    """Existing loopback backend or authenticated local gateway; no redirects."""
    def __init__(self, url: str, headers_file: str | None, timeout: float):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and not parsed.username
                and not parsed.password and not parsed.query and not parsed.fragment, "loopback_url_required")
        self.url, self.timeout, self.next_id = url, timeout, 1
        self.headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                        "MCP-Protocol-Version": "2025-06-18"}
        if headers_file:
            path = Path(headers_file)
            require(path.stat().st_mode & 0o077 == 0, "headers_file_must_be_private")
            extra = json.loads(path.read_text())
            require(isinstance(extra, dict) and set(extra) <= {"Authorization", "Cf-Access-Jwt-Assertion"}
                    and all(isinstance(v, str) and "\n" not in v and "\r" not in v for v in extra.values()),
                    "invalid_auth_headers")
            self.headers.update(extra)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                return None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method: str, params: dict) -> dict:
        request_id = self.next_id
        self.next_id += 1
        request = urllib.request.Request(self.url, data=json.dumps({"jsonrpc": "2.0", "id": request_id,
            "method": method, "params": params}).encode(), headers=self.headers, method="POST")
        with self.opener.open(request, timeout=self.timeout) as response:
            raw = response.read(4_194_305)
            require(len(raw) <= 4_194_304, "response_too_large")
            session = response.headers.get("Mcp-Session-Id")
            if session:
                self.headers["Mcp-Session-Id"] = session
            if "text/event-stream" in response.headers.get("Content-Type", ""):
                for line in raw.decode().splitlines():
                    if line.startswith("data:"):
                        value = json.loads(line[5:])
                        if value.get("id") == request_id:
                            return value
                raise RuntimeError("missing_sse_response")
            value = json.loads(raw)
            require(value.get("id") == request_id, "unexpected_response_id")
            return value

    def start(self) -> None:
        result = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "notes-live-smoke", "version": "1"}})
        require(result.get("result", {}).get("protocolVersion") == "2025-06-18", "unexpected_protocol")

    def call_tool(self, name: str, arguments: dict):
        result = self.request("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        content = result.get("content", [])
        require(bool(content) and content[0].get("type") == "text", "missing_tool_content")
        envelope = json.loads(content[0]["text"])
        if envelope.get("success") is not True:
            raise ToolFailure(envelope.get("error", {}).get("code", "unknown"))
        return envelope.get("data")

    def close(self) -> None:
        pass


def discover(client, account: str | None = None) -> dict:
    tools = client.request("tools/list", {}).get("result", {}).get("tools", [])
    require(TOOLS <= {item.get("name") for item in tools}, "notes_tool_discovery_failed")
    result = {"notes_tools": sorted(TOOLS), "accounts": client.call_tool("notes_list_accounts", {})}
    if account is not None:
        require(account.startswith("notes_v1_"), "opaque_account_reference_required")
        result["folders"] = client.call_tool("notes_list_folders", {"account_id": account})
    return result


def matching_notes(client, folder: str, title: str) -> list:
    page = client.call_tool("notes_search_notes", {"folder_id": folder, "query": title, "limit": 1000})
    require(isinstance(page, dict) and page.get("truncated") is False, "incomplete_fixture_search")
    return [item for item in page["items"] if item.get("name") == title]


def verify(client, folder: str, journal: Path, mode: str) -> dict:
    require(folder.startswith("notes_v1_"), "opaque_folder_reference_required")
    require(not journal.exists(), "journal_exists_inspect_previous_outcome_do_not_retry")
    discovered = client.request("tools/list", {}).get("result", {}).get("tools", [])
    require(TOOLS <= {item.get("name") for item in discovered}, "notes_tool_discovery_failed")
    info = client.call_tool("mail_server_info", {})
    require(info.get("notes_mutation_mode") == mode, "unexpected_notes_policy")
    run_id = uuid.uuid4().hex
    title = "Apple Platform MCP Live Test " + run_id
    require(not matching_notes(client, folder, title), "fixture_already_exists")
    state = {"run_id": run_id, "folder_id": folder, "title": title, "text": TEXT,
             "idempotency_key": "notes-smoke-" + run_id, "status": "create_outcome_unknown",
             "mode": mode, "client_verified": False}
    write_private(journal, state, create_only=True)  # Persist BEFORE dispatch, including failed/ambiguous attempts.
    request = {"folder_id": folder, "title": title, "text": TEXT, "idempotency_key": state["idempotency_key"]}
    if mode == "denied":
        try:
            client.call_tool("notes_create_note", request)
        except ToolFailure as error:
            require(error.code == "notesPolicyDenied", "unexpected_denial_code")
        else:
            raise RuntimeError("write_was_not_denied")
        require(not matching_notes(client, folder, title), "denied_write_created_note")
        state["status"] = "denial_verified"
    else:
        created = client.call_tool("notes_create_note", request)
        require(isinstance(created, dict) and isinstance(created.get("id"), str), "missing_created_reference")
        state["note_id"] = created["id"]
        state["status"] = "created_retry_not_yet_verified"
        write_private(journal, state)
        repeated = client.call_tool("notes_create_note", request)
        require(repeated.get("id") == created["id"], "retry_returned_different_note")
        state["retry_verified"] = True
        state["status"] = "created_retry_verified_read_pending"
        write_private(journal, state)
        read = client.call_tool("notes_get_note", {"note_id": created["id"]})
        require(read.get("name") == title and read.get("locked") is False
                and read.get("truncated") is False, "note_metadata_mismatch")
        actual = read.get("text", "").replace("\r\n", "\n").replace("\r", "\n")
        require(title in actual and all(line in actual for line in TEXT.splitlines()), "note_text_mismatch")
        found = matching_notes(client, folder, title)
        require(len(found) == 1 and found[0].get("id") == created["id"], "duplicate_or_missing_note")
        state["status"] = "mcp_verified_visual_check_pending"
    write_private(journal, state)
    return {"status": state["status"], "run_id": run_id, "notes_tools": sorted(TOOLS),
            "journal": str(journal), "existing_notes_changed": False, "fixture_retained": mode == "allowed"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--binary")
    target.add_argument("--url")
    parser.add_argument("--config")
    parser.add_argument("--headers-file", help="Private JSON file, local gateway authentication only")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--discover", action="store_true")
    parser.add_argument("--account-reference-file", help="Selected account for read-only folder discovery")
    parser.add_argument("--folder-reference-file", help="Private text file holding the exact opaque folder reference")
    parser.add_argument("--journal")
    parser.add_argument("--mode", choices=["allowed", "denied"], default="allowed")
    parser.add_argument("--confirm-live", action="store_true")
    args = parser.parse_args()
    if args.binary:
        require(bool(args.config) and Path(args.config).is_absolute(), "absolute_isolated_config_required")
        client = MCPProcess(os.path.abspath(args.binary), args.config, args.timeout)
    else:
        client = HTTPClient(args.url, args.headers_file, args.timeout)
    try:
        client.start()
        if args.discover:
            account = Path(args.account_reference_file).read_text().strip() if args.account_reference_file else None
            output = discover(client, account)
        else:
            require(args.confirm_live and bool(args.folder_reference_file) and bool(args.journal),
                    "explicit_fixture_and_live_confirmation_required")
            folder = Path(args.folder_reference_file).read_text().strip()
            output = verify(client, folder, Path(args.journal), args.mode)
        print(json.dumps(output, sort_keys=True))
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        # Raw adapter/HTTP errors can contain private data or authentication headers.
        print(json.dumps({"status": "failed_inspect_private_journal", "error_type": type(error).__name__}))
        raise SystemExit(1)
