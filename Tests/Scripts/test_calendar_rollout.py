"""Calendar rollout guard tests; no EventKit, UI, or network access."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('calendar_smoke', ROOT/'Scripts/verify-calendar-live-smoke.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class FakeClient:
    def __init__(self, allowed=True, fail=False):
        self.allowed, self.fail = allowed, fail
        self.items, self.results, self.creates = {}, {}, 0
        self.name = 'Apple Platform MCP Live Test'
        self.outcome_status = 'succeeded'

    def request(self, *args):
        return {'result': {'tools': [{'name': n} for n in smoke.TOOLS]}}

    def call_tool(self, name, args):
        if name == 'calendar_list_calendars':
            return [{'id': 'cal_v1_test', 'name': self.name, 'can_write': True, 'policy_allows_write': self.allowed}]
        if name == 'calendar_create_event':
            if not self.allowed:
                raise smoke.ToolFailure('calendarPolicyDenied')
            key = args['idempotency_key']
            if key in self.results:
                return self.results[key]
            self.creates += 1
            if self.fail:
                raise TimeoutError()
            event_id = 'event_' + str(self.creates)
            self.items[event_id] = dict(args, id=event_id)
            self.results[key] = {'event_id': event_id, 'warnings': ['overlapping_events_detected']}
            return self.results[key]
        if name == 'calendar_get_creation_outcome':
            result = self.results.get(args['idempotency_key'])
            return {'status': self.outcome_status if result else 'not_found', 'result': result}
        if name == 'calendar_get_event':
            return self.items[args['event_id']]
        if name == 'calendar_search_events':
            return {'items': list(self.items.values()), 'truncated': False}
        if name == 'calendar_check_conflicts':
            return {'conflicts': list(self.items.values()), 'status': 'complete'}
        raise AssertionError(name)


class CalendarRolloutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.manifest = Path(self.temp.name)/'fixture.json'

    def test_signed_hardened_runtime_includes_calendar_permission(self):
        entitlements = plistlib.loads((ROOT/'Config/ApplePlatformMCP.entitlements').read_bytes())
        self.assertTrue(entitlements['com.apple.security.personal-information.calendars'])
        self.assertTrue(entitlements['com.apple.security.automation.apple-events'])
        self.assertNotIn('com.apple.security.app-sandbox', entitlements)

    def test_create_and_restart_replay_create_exactly_three_events(self):
        client = FakeClient()
        smoke.verify(client, 'cal_v1_test', self.manifest, 'create')
        result = smoke.verify(client, 'cal_v1_test', self.manifest, 'replay')
        self.assertEqual(client.creates, 3)
        self.assertTrue(result['restart_replay_verified'])
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o600)

    def test_unknown_attempt_retained_and_new_dispatch_refused(self):
        client = FakeClient(fail=True)
        with self.assertRaises(TimeoutError):
            smoke.verify(client, 'cal_v1_test', self.manifest, 'create')
        self.assertEqual(json.loads(self.manifest.read_text())['status'], 'outcome_unknown')
        for mode in ['create', 'replay']:
            with self.assertRaises(RuntimeError):
                smoke.verify(client, 'cal_v1_test', self.manifest, mode)
        self.assertEqual(client.creates, 1)

    def test_missing_durable_result_refuses_replay(self):
        client = FakeClient()
        smoke.verify(client, 'cal_v1_test', self.manifest, 'create')
        client.outcome_status = 'outcome_unknown'
        with self.assertRaisesRegex(RuntimeError, 'durable_outcome_missing'):
            smoke.verify(client, 'cal_v1_test', self.manifest, 'replay')
        self.assertEqual(client.creates, 3)

    def test_denied_write_never_reserves_key_or_creates(self):
        client = FakeClient(allowed=False)
        result = smoke.verify(client, 'cal_v1_test', self.manifest, 'deny')
        self.assertEqual(result['fixtures_created'], 0)
        self.assertEqual(client.creates, 0)

    def test_only_exact_dedicated_calendar_can_be_targeted(self):
        client = FakeClient()
        client.name = 'Work'
        with self.assertRaisesRegex(RuntimeError, 'dedicated_writable_test_calendar_required'):
            smoke.verify(client, 'cal_v1_test', self.manifest, 'create')
        self.assertFalse(self.manifest.exists())
        self.assertEqual(client.creates, 0)


if __name__ == '__main__':
    unittest.main()
