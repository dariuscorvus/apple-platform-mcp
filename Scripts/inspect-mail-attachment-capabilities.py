#!/usr/bin/env python3
"""Read installed Mail dictionary without Apple Events or mailbox reads.

Declarations are evidence of an API surface, never runtime acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

def inspect(path):
    data = Path(path).read_bytes()
    dictionary = ET.fromstring(data)
    def cls(name):
        return dictionary.find(".//class[@name='" + name + "']")
    def has(node, query):
        return node is not None and node.find(query) is not None
    received = cls('mail attachment')
    outgoing = cls('outgoing message')
    attachment = cls('attachment')
    return {
        'dictionary_sha256': hashlib.sha256(data).hexdigest(),
        'declared': {
            'received_save': has(received, "responds-to[@command='save']"),
            'received_id': has(received, "property[@name='id']"),
            'received_downloaded': has(received, "property[@name='downloaded']"),
            'received_size_is_approximate': has(received, "property[@name='file size']"),
            'outgoing_save': has(outgoing, "responds-to[@command='save']"),
            'outgoing_id': has(outgoing, "property[@name='id']"),
            'outgoing_file_attachment': has(attachment, "property[@name='file name']"),
        },
        'live_export_verified': False,
        'draft_restart_identity_verified': False,
        'draft_insert_remove_verified': False,
        'client_upload_download_verified': False,
        'mail_content_read': False,
        'apple_events_sent': False,
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dictionary', default='/System/Applications/Mail.app/Contents/Resources/Mail.sdef')
    args = parser.parse_args()
    print(json.dumps(inspect(args.dictionary), indent=2, sort_keys=True))
