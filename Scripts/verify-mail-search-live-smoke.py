#!/usr/bin/env python3
"""Opt-in read-only Mail search regression; prints counts/timings, never mail values.

Use an isolated signed loopback host first. No body, attachment, mutation or
permission-request tools are called. The existing Inbox provides the positive
reference; no test messages are created. Tax searches are explicitly opt-in.
"""
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import re
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location('calendar_smoke', Path(__file__).with_name('verify-calendar-live-smoke.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
require = module.require


def received_datetime(value):
    # MCP.Value currently uses Codable's seconds since 2001 for Mail dates.
    return (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=value)
            if isinstance(value, (int, float))
            else datetime.fromisoformat(value.replace('Z', '+00:00')))


def verify(client, tax_queries=False, progress=None):
    rows = []

    def search(label, arguments):
        start = time.monotonic()
        page = client.call_tool('mail_search_messages', arguments)
        items = page['messages']
        require(len(items) <= arguments.get('limit', 20), 'result_limit_exceeded')
        dates = [item['receivedAt'] for item in items if item.get('receivedAt')]
        require(dates == sorted(dates, reverse=True), 'result_order_changed')
        rows.append({'check': label, 'duration_ms': round((time.monotonic() - start) * 1000),
                     'matches': len(items), 'has_next_cursor': page.get('nextCursor') is not None})
        if progress:
            progress(rows[-1])
        return page

    info = client.call_tool('mail_server_info', {})
    page = search('inbox_baseline', {'limit': 3})
    require(bool(page['messages']), 'nonempty_inbox_required')
    first = page['messages'][0]
    scope = {'account_ids': [first['accountID']], 'mailbox_ids': [first['mailboxID']], 'scope': 'mailbox'}
    subject = first.get('subject', '')
    require(bool(subject.strip()), 'nonempty_reference_subject_required')
    subject_query = {**scope, 'subject': subject, 'limit': 3}
    exact = search('known_subject', subject_query)
    require(first['id'] in [item['id'] for item in exact['messages']], 'known_subject_missing')
    pagination_query, pagination_reference = subject_query, exact
    for case in [subject.lower(), subject.upper()]:
        variant = search('subject_case_variant', {**subject_query, 'subject': case})
        require([item['id'] for item in variant['messages']] == [item['id'] for item in exact['messages']],
                'case_variant_results_differ')
    sender = (first.get('sender') or {}).get('address')
    if sender:
        sender_query = {**scope, 'from': sender, 'limit': 3}
        sender_page = search('known_sender', sender_query)
        require(first['id'] in [item['id'] for item in sender_page['messages']], 'known_sender_missing')
        if len(sender_page['messages']) > 1:
            pagination_query, pagination_reference = sender_query, sender_page
    for field, summary_key, value in [('unread_only', 'isRead', False), ('flagged_only', 'isFlagged', True)]:
        status_page = search(field, {**subject_query, field: True})
        require(all(item[summary_key] == value for item in status_page['messages']), 'status_filter_mismatch')
        if first[summary_key] == value:
            require(first['id'] in [item['id'] for item in status_page['messages']], 'known_status_match_missing')
    baseline_dates = [received_datetime(item['receivedAt']) for item in page['messages'] if item.get('receivedAt')]
    if len(baseline_dates) > 1:
        # A small known recent window exercises native pagination and merging
        # across accounts without asking Mail for the entire mailbox history.
        recent_query = {'after': (min(baseline_dates) - timedelta(seconds=1)).isoformat(), 'limit': 3}
        recent_page = search('recent_window', recent_query)
        if len(recent_page['messages']) > 1:
            pagination_query, pagination_reference = recent_query, recent_page
    first_page = search('pagination_first', {**pagination_query, 'limit': 1})
    require(first_page['messages'] == pagination_reference['messages'][:1], 'first_page_changed')
    if len(pagination_reference['messages']) > 1:
        require(first_page.get('nextCursor'), 'missing_continuation')
        second = search('pagination_second', {**pagination_query, 'limit': 1, 'cursor': first_page['nextCursor']})
        require(second['messages'] == pagination_reference['messages'][1:2], 'continuation_changed')
    date = first.get('receivedAt')
    if date:
        received = received_datetime(date)
        bounded = search('date_bounds', {**subject_query,
            'after': (received - timedelta(seconds=1)).isoformat(),
            'before': (received + timedelta(seconds=1)).isoformat()})
        require(first['id'] in [item['id'] for item in bounded['messages']], 'bounded_reference_missing')
        exclusive = search('strict_after', {**subject_query, 'after': received.isoformat()})
        require(first['id'] not in [item['id'] for item in exclusive['messages']], 'after_not_strict')
    missing = search('no_match', {**scope, 'subject': 'mcp-no-match-' + uuid.uuid4().hex, 'limit': 1})
    require(not missing['messages'] and missing.get('nextCursor') is None, 'unexpected_negative_match')
    if tax_queries:
        for field, term in [('from', 'accountable'), ('subject', 'Steuer'), ('subject', 'Umsatzsteuer'),
                            ('subject', 'Finanzamt'), ('subject', 'ELSTER')]:
            search('tax_' + term.lower(), {field: term, 'limit': 3})
    return {'status': 'passed', 'observed_at_utc': datetime.now(timezone.utc).isoformat(),
            'checks': rows, 'server_build_commit': info.get('build_commit'),
            'mail_values_persisted': False, 'writes_performed': False,
            'scope': 'inbox_and_one_explicit_mailbox', 'chatgpt_client_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--headers-file')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--tax-queries', action='store_true')
    parser.add_argument('--progress', action='store_true', help='Print sanitized per-query timings to stderr')
    args = parser.parse_args()
    client = module.HTTPClient(args.url, args.headers_file, args.timeout)
    try:
        client.start()
        progress = (lambda row: print(json.dumps(row), file=sys.stderr, flush=True)) if args.progress else None
        print(json.dumps(verify(client, args.tax_queries, progress), sort_keys=True))
    finally:
        client.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        check = str(error) if isinstance(error, RuntimeError) and re.fullmatch(r'[a-z_]{1,80}', str(error)) else None
        print(json.dumps({'status': 'failed', 'error_type': type(error).__name__,
                          'code': getattr(error, 'code', 'not_exposed'), 'check': check}))
        raise SystemExit(1)
