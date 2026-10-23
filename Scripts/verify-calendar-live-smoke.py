#!/usr/bin/env python3
"""Opt-in synthetic Calendar acceptance. Keep the private manifest for safe restart replay."""
from __future__ import annotations
import argparse
from datetime import datetime, timedelta
import importlib.util
import json
from pathlib import Path
import uuid
from zoneinfo import ZoneInfo

spec = importlib.util.spec_from_file_location('notes_smoke', Path(__file__).with_name('verify-notes-live-smoke.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
require, write_private, ToolFailure = module.require, module.write_private, module.ToolFailure
TOOLS = {'calendar_' + name for name in ('list_calendars', 'search_events', 'get_event', 'check_conflicts', 'create_event', 'get_creation_outcome')}
TEXT = 'Synthetischer Kalender-Test: äöü ÄÖÜ ß\nZweite Zeile: <tag> & "Zeichen"'



class HTTPClient(module.HTTPClient):
    def start(self):
        result = self.request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'calendar-live-smoke', 'version': '1'}})
        # The existing native stateless endpoint owns one SDK server instance.
        # A separate operator connection can attach after its first initialization.
        if result.get('error', {}).get('code') == -32600 and result['error'].get('data', {}).get('detail') == 'Server is already initialized':
            require('result' in self.request('tools/list', {}), 'initialized_server_not_ready')
            return
        require(result.get('result', {}).get('protocolVersion') == '2025-06-18', 'unexpected_protocol')


def discover(client):
    names = {t['name'] for t in client.request('tools/list', {})['result']['tools']}
    require(TOOLS <= names, 'calendar_tool_discovery_failed')
    return {'tools': sorted(TOOLS), 'calendars': client.call_tool('calendar_list_calendars', {})}


def fixtures(calendar_id, run_id):
    base = (datetime.now(ZoneInfo('Europe/Berlin')) + timedelta(days=14)).replace(hour=10, minute=0, second=0, microsecond=0)
    requests = []
    for label, start, end, all_day in [
        ('Termin', base, base + timedelta(hours=1), False),
        ('Überschneidung', base + timedelta(minutes=30), base + timedelta(minutes=90), False),
        ('Ganztägig', base + timedelta(days=1), base + timedelta(days=2), True),
    ]:
        requests.append({'calendar_id': calendar_id, 'title': f'Apple Platform MCP Live Test {run_id} {label}',
            'time': {'start': start.date().isoformat() if all_day else start.isoformat(),
                     'end': end.date().isoformat() if all_day else end.isoformat(),
                     'time_zone': 'Europe/Berlin', 'all_day': all_day},
            'notes': TEXT, 'location': 'Synthetischer Testort', 'idempotency_key': f'calendar-live-{run_id}-{len(requests)}'})
    return requests


def verify(client, calendar_id, manifest, mode):
    calendars = discover(client)['calendars']
    target = next((c for c in calendars if c['id'] == calendar_id), None)
    require(target is not None and target['name'] == 'Apple Platform MCP Live Test' and target['can_write'], 'dedicated_writable_test_calendar_required')
    if mode == 'replay':
        require(manifest.exists(), 'existing_manifest_required')
        state = json.loads(manifest.read_text())
        require(state['calendar_id'] == calendar_id and state['status'] == 'verified', 'only_completed_manifest_can_replay')
        for request, result in zip(state['requests'], state['results']):
            outcome = client.call_tool('calendar_get_creation_outcome', {'idempotency_key': request['idempotency_key']})
            require(outcome.get('status') == 'succeeded' and outcome.get('result') == result, 'durable_outcome_missing_no_retry')
            require(client.call_tool('calendar_create_event', request) == result, 'replay_changed_result')
        state['restart_replay_verified'] = True
    else:
        require(not manifest.exists(), 'manifest_exists_inspect_outcome_do_not_retry')
        run_id = uuid.uuid4().hex
        state = {'run_id': run_id, 'calendar_id': calendar_id, 'requests': fixtures(calendar_id, run_id), 'results': [], 'status': 'prepared'}
        write_private(manifest, state, create_only=True)
        require(target['policy_allows_write'] == (mode == 'create'), 'unexpected_write_policy')
        for request in state['requests'][:1 if mode == 'deny' else 3]:
            state['status'] = 'outcome_unknown'
            write_private(manifest, state)
            if mode == 'deny':
                try:
                    client.call_tool('calendar_create_event', request)
                except ToolFailure as error:
                    require(error.code == 'calendarPolicyDenied', 'unexpected_denial')
                else:
                    raise RuntimeError('write_not_denied')
                require(client.call_tool('calendar_get_creation_outcome', {'idempotency_key': request['idempotency_key']})['status'] == 'not_found', 'denied_write_reserved_key')
                state['status'] = 'denial_verified'
                write_private(manifest, state)
                return {'status': state['status'], 'fixtures_created': 0}
            result = client.call_tool('calendar_create_event', request)
            state['results'].append(result)
            write_private(manifest, state)
            require(client.call_tool('calendar_create_event', request) == result, 'retry_changed_result')
        require('overlapping_events_detected' in state['results'][1]['warnings'], 'overlap_warning_missing')
    for request, result in zip(state['requests'], state['results']):
        event = client.call_tool('calendar_get_event', {'event_id': result['event_id']})
        require(event['title'] == request['title'] and event['notes'] == TEXT and event['location'] == request['location'], 'event_content_mismatch')
        actual, expected = event['time'], request['time']
        require(actual['all_day'] == expected['all_day'], 'all_day_mismatch')
        if expected['all_day']:
            require(actual['start'] == expected['start'] and actual['end'] == expected['end'], 'all_day_date_shift')
        else:
            require(datetime.fromisoformat(actual['start']) == datetime.fromisoformat(expected['start']) and datetime.fromisoformat(actual['end']) == datetime.fromisoformat(expected['end']), 'timed_date_shift')
    first = state['requests'][0]['time']
    search_time = dict(first)
    # Use the zone's actual offset on the exclusive end, including DST changes.
    search_time['end'] = datetime.fromisoformat(state['requests'][2]['time']['end']).replace(tzinfo=ZoneInfo('Europe/Berlin')).isoformat()
    page = client.call_tool('calendar_search_events', {'time': search_time, 'calendar_ids': [calendar_id], 'query': state['run_id'], 'limit': 1000})
    require(not page['truncated'] and {e['id'] for e in page['items']} == {r['event_id'] for r in state['results']}, 'duplicate_missing_or_truncated_fixtures')
    conflict = client.call_tool('calendar_check_conflicts', {'time': first})
    require({r['event_id'] for r in state['results'][:2]} <= {e['id'] for e in conflict['conflicts']}, 'overlap_detection_failed')
    state['status'] = 'verified'
    write_private(manifest, state)
    return {'status': 'verified', 'fixtures_retained': 3, 'restart_replay_verified': state.get('restart_replay_verified', False), 'conflict_status': conflict['status']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--binary')
    target.add_argument('--url')
    parser.add_argument('--config')
    parser.add_argument('--headers-file')
    parser.add_argument('--discover', action='store_true')
    parser.add_argument('--calendar-reference-file')
    parser.add_argument('--manifest')
    parser.add_argument('--mode', choices=['create', 'replay', 'deny'], default='create')
    parser.add_argument('--confirm-live', action='store_true')
    args = parser.parse_args()
    client = module.MCPProcess(args.binary, args.config, 60) if args.binary else HTTPClient(args.url, args.headers_file, 60)
    try:
        client.start()
        if args.discover:
            result = discover(client)
        else:
            require(args.confirm_live and args.calendar_reference_file and args.manifest, 'explicit_fixture_confirmation_required')
            result = verify(client, Path(args.calendar_reference_file).read_text().strip(), Path(args.manifest), args.mode)
        print(json.dumps(result))
    finally:
        client.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'status': 'failed_inspect_private_manifest', 'error_type': type(error).__name__, 'code': str(error) if isinstance(error, ToolFailure) else None}))
        raise SystemExit(1)
