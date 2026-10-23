#!/usr/bin/env python3
"""Read-only bounded Contacts live verification; sanitized output only.

Queries must come from a private explicit JSON file (1–4 names). Never persists
contact names, references, addresses or phone values. Multiple matches are left
unresolved and fail the acceptance gate; no arbitrary first-contact selection.
"""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('calendar_smoke', Path(__file__).with_name('verify-calendar-live-smoke.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HTTPClient = module.HTTPClient
MCPProcess = module.module.MCPProcess
require = module.require
TOOLS = {'contacts_list_containers', 'contacts_search_contacts', 'contacts_get_contact'}


def verify(client, queries):
    require(isinstance(queries, list) and 1 <= len(queries) <= 4 and
            all(isinstance(q, str) and 2 <= len(q.strip()) and len(q.encode()) <= 256 for q in queries), 'explicit_bounded_queries_required')
    tools = client.request('tools/list', {}).get('result', {}).get('tools', [])
    selected = [t for t in tools if t.get('name') in TOOLS]
    require({t['name'] for t in selected} == TOOLS, 'contacts_catalog_missing')
    require(all(t.get('annotations', {}).get('readOnlyHint') is True for t in selected), 'contacts_not_readonly')
    containers = client.call_tool('contacts_list_containers', {})
    require(containers.get('authorization') in ['authorized', 'limited'], 'contacts_permission_required')
    results = []
    for query in queries:
        page = client.call_tool('contacts_search_contacts', {'query': query, 'fields': ['name'], 'limit': 5})
        items = page.get('items', [])
        row = {'matches': len(items), 'search_complete': page.get('scan_complete') is True,
               'truncated': page.get('truncated') is True, 'detail_read': False}
        if len(items) == 1 and row['search_complete'] and not row['truncated']:
            item = items[0]
            detail = client.call_tool('contacts_get_contact', {'contact_id': item['id']})
            contact = detail.get('contact', {})
            require(contact.get('summary', {}).get('id') == item['id'] and
                    contact['summary']['container_id'] == item['container_id'], 'exact_contact_reference_mismatch')
            require(not set(contact) & {'photos', 'notes', 'addresses', 'birthdays'}, 'unrelated_contact_fields')
            require(contact.get('truncated') is False, 'contact_detail_truncated')
            row.update(detail_read=True, email_count=len(contact.get('emails', [])), phone_count=len(contact.get('phones', [])))
        results.append(row)
    passed = all(row['detail_read'] for row in results)
    return {'status': 'passed' if passed else 'incomplete_or_ambiguous', 'authorization': containers['authorization'],
            'container_count': len(containers.get('items', [])), 'container_scan_complete': containers.get('scan_complete'),
            'contacts_tools': sorted(TOOLS), 'queries': results, 'contact_values_persisted': False,
            'writes_performed': False, 'chatgpt_client_verified': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument('--binary'); target.add_argument('--url')
    p.add_argument('--config'); p.add_argument('--headers-file'); p.add_argument('--queries-file', required=True)
    p.add_argument('--timeout', type=float, default=60)
    a = p.parse_args(); f = Path(a.queries_file)
    require(f.is_absolute() and f.stat().st_mode & 0o077 == 0, 'private_absolute_queries_file_required')
    queries = json.loads(f.read_text())
    if a.binary:
        require(a.config and Path(a.config).is_absolute(), 'absolute_isolated_config_required')
        client = MCPProcess(str(Path(a.binary).resolve()), a.config, a.timeout)
    else: client = HTTPClient(a.url, a.headers_file, a.timeout)
    try:
        client.start(); result = verify(client, queries); print(json.dumps(result, sort_keys=True))
        return 0 if result['status'] == 'passed' else 2
    finally: client.close()


if __name__ == '__main__':
    try: raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'status': 'failed', 'error_type': type(error).__name__,
                          'code': getattr(error, 'code', 'not_exposed')}))
        raise SystemExit(1)
