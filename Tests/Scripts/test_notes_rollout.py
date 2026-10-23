"""Synthetic guardrail tests; no Apple Events, sign-in, or network requests."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load("notes_smoke", "verify-notes-live-smoke.py")
build = load("notes_build", "build-signed-notes-candidate.py")


class FakeClient:
    def __init__(self, mode="allowed", fail=False, duplicate=False):
        self.mode, self.fail, self.duplicate = mode, fail, duplicate
        self.creates = 0
        self.item = None
        self.calls = []

    def request(self, method, params):
        return {"result": {"tools": [{"name": name} for name in smoke.TOOLS]}}

    def call_tool(self, name, arguments):
        self.calls.append(name)
        if name == "mail_server_info":
            return {"notes_mutation_mode": self.mode}
        if name == "notes_search_notes":
            items = [self.item] if self.item else []
            return {"items": items * (2 if self.duplicate else 1), "truncated": False}
        if name == "notes_create_note":
            if self.mode == "denied":
                raise smoke.ToolFailure("notesPolicyDenied")
            if self.item:
                return self.item
            self.creates += 1
            if self.fail:
                raise TimeoutError()
            self.item = {"id": "notes_v1_fixture", "name": arguments["title"], "locked": False,
                         "truncated": False, "text": arguments["title"] + "\n" + arguments["text"]}
            return self.item
        if name == "notes_get_note":
            return self.item
        raise AssertionError("Unexpected tool")


class NotesRolloutTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.journal = Path(self.directory.name) / "journal.json"

    def test_signed_identity_selection_excludes_other_certificate_types(self):
        output = ('1) ' + 'A' * 40 + ' "Apple Development: Example (ABCDEFGHIJ)"\n'
                  '2) ' + 'B' * 40 + ' "Developer ID Application: Example (1234567890)"\n')
        self.assertEqual(build.identities(output), [('B' * 40, '1234567890')])
        self.assertEqual(build.identities('Signature=adhoc'), [])

    def test_private_atomic_journal_cannot_overwrite_an_existing_attempt(self):
        smoke.write_private(self.journal, {"status": "unknown"}, create_only=True)
        self.assertEqual(self.journal.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            smoke.write_private(self.journal, {"status": "replacement"}, create_only=True)
        self.assertEqual(json.loads(self.journal.read_text())["status"], "unknown")

    def test_create_retry_and_read_use_only_explicit_fixture(self):
        client = FakeClient()
        outcome = smoke.verify(client, "notes_v1_folder", self.journal, "allowed")
        self.assertEqual(client.creates, 1)
        self.assertEqual(outcome["status"], "mcp_verified_visual_check_pending")
        self.assertEqual(client.calls.count("notes_create_note"), 2)
        self.assertNotIn("notes_delete_note", client.calls)
        self.assertEqual(json.loads(self.journal.read_text())["client_verified"], False)

    def test_ambiguous_create_is_retained_and_cannot_restart(self):
        client = FakeClient(fail=True)
        with self.assertRaises(TimeoutError):
            smoke.verify(client, "notes_v1_folder", self.journal, "allowed")
        self.assertEqual(json.loads(self.journal.read_text())["status"], "create_outcome_unknown")
        with self.assertRaisesRegex(RuntimeError, "journal_exists"):
            smoke.verify(client, "notes_v1_folder", self.journal, "allowed")
        self.assertEqual(client.creates, 1)

    def test_denied_write_creates_no_note(self):
        client = FakeClient(mode="denied")
        result = smoke.verify(client, "notes_v1_folder", self.journal, "denied")
        self.assertEqual(result["status"], "denial_verified")
        self.assertEqual(client.creates, 0)

    def test_policy_mismatch_stops_before_creation(self):
        client = FakeClient(mode="allowed")
        with self.assertRaisesRegex(RuntimeError, "unexpected_notes_policy"):
            smoke.verify(client, "notes_v1_folder", self.journal, "denied")
        self.assertEqual(client.creates, 0)
        self.assertFalse(self.journal.exists())

    def test_duplicate_results_cannot_pass_acceptance(self):
        client = FakeClient(duplicate=True)
        with self.assertRaisesRegex(RuntimeError, "duplicate_or_missing_note"):
            smoke.verify(client, "notes_v1_folder", self.journal, "allowed")
        self.assertEqual(json.loads(self.journal.read_text())["status"], "created_retry_verified_read_pending")

    def test_raw_folder_names_never_select_a_write_target(self):
        client = FakeClient()
        with self.assertRaisesRegex(RuntimeError, "opaque_folder_reference_required"):
            smoke.verify(client, "Folder name", self.journal, "allowed")
        self.assertEqual(client.creates, 0)

    def test_http_auth_cannot_be_sent_to_remote_or_redirect_target(self):
        for url in ["https://example.com/mcp", "http://localhost/mcp", "http://127.0.0.1@mcp.example/mcp",
                    "http://127.0.0.1/mcp?token=private"]:
            with self.assertRaises(RuntimeError):
                smoke.HTTPClient(url, None, 1)

    def test_world_readable_header_file_is_refused(self):
        path = Path(self.directory.name) / "headers.json"
        path.write_text('{"Authorization":"Bearer synthetic"}')
        path.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, "headers_file_must_be_private"):
            smoke.HTTPClient("http://127.0.0.1:3766/apple-platform", str(path), 1)


if __name__ == "__main__":
    unittest.main()
