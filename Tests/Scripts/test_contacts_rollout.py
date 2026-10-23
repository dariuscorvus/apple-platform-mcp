"""Synthetic Contacts smoke guardrails; no contacts or services accessed."""
import importlib.util
from pathlib import Path
import plistlib
import unittest
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('contacts_smoke', ROOT/'Scripts/verify-contacts-live-smoke.py')
smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)
class Fake:
    def __init__(self, count=1, complete=True): self.count=count; self.complete=complete; self.calls=[]
    def request(self, *args): return {'result': {'tools': [{'name': t, 'annotations': {'readOnlyHint': True}} for t in smoke.TOOLS]}}
    def call_tool(self, name, args):
        self.calls.append(name)
        if name=='contacts_list_containers': return {'authorization': 'limited', 'items': [], 'scan_complete': True}
        if name=='contacts_search_contacts': return {'items': [{'id':'synthetic', 'container_id':'container'}]*self.count, 'scan_complete': self.complete, 'truncated': not self.complete}
        if name=='contacts_get_contact': return {'contact': {'summary': {'id':'synthetic', 'container_id':'container'}, 'emails': [{'value':'secret@example.invalid'}], 'phones': [], 'truncated': False}}
        raise AssertionError('Unexpected tool')
class ContactsRolloutTests(unittest.TestCase):
    def test_signed_requirements(self):
        ent=plistlib.loads((ROOT/'Config/ApplePlatformMCP.entitlements').read_bytes())
        info=plistlib.loads((ROOT/'Config/ApplePlatformMCP-Info.plist').read_bytes())
        self.assertTrue(ent['com.apple.security.personal-information.addressbook'])
        self.assertTrue(info['NSContactsUsageDescription'])
        self.assertNotIn('com.apple.developer.contacts.notes',ent)
    def test_no_arbitrary_selection_or_incomplete_scan(self):
        for count,complete in [(0,True),(2,True),(1,False)]:
            client=Fake(count,complete); result=smoke.verify(client,['Synthetic'])
            self.assertNotEqual(result['status'],'passed')
            self.assertNotIn('contacts_get_contact',client.calls)
    def test_sanitized_evidence_and_read_only_calls(self):
        client=Fake();result=smoke.verify(client,['Synthetic'])
        self.assertEqual(result['status'],'passed')
        self.assertFalse(result['writes_performed'])
        self.assertNotIn('secret',str(result));self.assertNotIn('synthetic',str(result))
        self.assertTrue(set(client.calls)<=smoke.TOOLS)
    def test_queries_must_be_explicit_and_bounded(self):
        for q in [[],['a'],['x'*257],['Synthetic']*5]:
            with self.assertRaises(RuntimeError): smoke.verify(Fake(),q)
if __name__=='__main__':unittest.main()
