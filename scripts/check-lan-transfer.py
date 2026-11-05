"""Check independent synthetic LAN vectors and transport boundaries; not Swift compilation."""
import base64
import hashlib
import hmac
import json
from pathlib import Path
import sys
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.exceptions import InvalidSignature

ROOT = Path(__file__).resolve().parents[1]


class LANProtocolChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = (ROOT / 'Tests/lan-transfer-v1.json').read_bytes()
        cls.vector = json.loads(cls.raw)
        dek = bytes(cls.vector['input_dek_bytes'])
        extracted = hmac.digest(b'workbench:lan:v1', dek, 'sha256')
        cls.auth = hmac.digest(extracted, b'authentication\x01', 'sha256')

    def test_scope_and_key_derivation(self):
        v = self.vector
        canonical = '\n'.join(('workbench-lan-scope-v1', v['canonical_server'], v['username'], v['key_id']))
        self.assertEqual(hashlib.sha256(canonical.encode()).hexdigest(), v['scope'])
        self.assertEqual(self.auth.hex(), v['authentication_key_hex'])

    def test_authenticated_discovery(self):
        v = self.vector
        canonical = '\n'.join(('workbench-lan-discovery-v1', v['scope'], v['key_id'], v['host_id'], v['certificate_sha256'], str(v['port']), v['name']))
        self.assertEqual(canonical, v['discovery_canonical'])
        expected = base64.b64decode(v['discovery_mac'], validate=True)
        self.assertTrue(hmac.compare_digest(hmac.digest(self.auth, canonical.encode(), 'sha256'), expected))
        self.assertFalse(hmac.compare_digest(hmac.digest(self.auth, (canonical + 'tampered').encode(), 'sha256'), expected))

    def test_request_signatures_and_utf8_body(self):
        v = self.vector
        signing = Ed25519PrivateKey.from_private_bytes(bytes(v['ed25519_seed_bytes']))
        public = signing.public_key()
        self.assertEqual(base64.b64encode(public.public_bytes(Encoding.Raw, PublicFormat.Raw)).decode(), v['public_key'])
        for request in v['requests']:
            with self.subTest(method=request['method']):
                canonical = '\n'.join(('workbench-lan-request-v1', v['host_id'], v['client_id'], str(request['timestamp']), request['nonce'], request['method'], request['path'], hashlib.sha256(request['body_utf8'].encode()).hexdigest()))
                self.assertEqual(canonical, request['canonical'])
                self.assertEqual(base64.b64encode(hmac.digest(self.auth, canonical.encode(), 'sha256')).decode(), request['account_mac'])
                signature = base64.b64decode(request['signature'], validate=True)
                self.assertEqual(signing.sign(canonical.encode()), signature)
                public.verify(signature, canonical.encode())
                with self.assertRaises(InvalidSignature):
                    public.verify(signature, canonical.encode() + b'tampered')

    def test_cross_repository_vectors_match_when_sibling_exists(self):
        sibling = ROOT.parent / 'workbench/tests/vectors/lan-transfer-v1.json'
        if sibling.exists():
            self.assertEqual(sibling.read_bytes(), self.raw)
        else:
            self.skipTest('Sibling Windows repository not checked out')

    def test_lan_code_cannot_call_cloud_api_or_use_bearer_token(self):
        directory = ROOT / 'ClipStudio/Services'
        for name in ('LANProtocol.swift', 'LANClient.swift', 'LANDiscovery.swift', 'LANTransferStore.swift'):
            text = (directory / name).read_text(encoding='utf-8')
            for forbidden in ('validatedAccount(', '.transferDocument(', '.transferBytes(', 'Bearer ', 'Authorization', 'ClipAPI('):
                self.assertNotIn(forbidden, text, name)
        files = (directory / 'LANFiles.swift').read_text(encoding='utf-8')
        self.assertNotIn('ClipAPI(', files)
        self.assertIn('copyToCloud', files)
        wrapper = (ROOT / 'ClipStudio/Features/LANTransferView.swift').read_text(encoding='utf-8')
        self.assertIn('confirmationDialog("改用云端中转？"', wrapper)
        self.assertIn('model.cloudFallback(record.id)', wrapper)

    def test_task_ownership_and_discovery_permissions(self):
        store = (ROOT / 'ClipStudio/ClipStore.swift').read_text(encoding='utf-8')
        app = (ROOT / 'ClipStudio/ClipStudioApp.swift').read_text(encoding='utf-8')
        self.assertIn('let lanTransfers = LANTransferStore()', store)
        self.assertIn('lanTransfers.configure(account: needsUnlock ? nil : account)', store)
        self.assertIn('store.lanTransfers.setForeground', app)
        project = (ROOT / 'project.yml').read_text(encoding='utf-8')
        self.assertIn('NSLocalNetworkUsageDescription:', project)
        self.assertIn('NSBonjourServices: ["_workbench._tcp"]', project)
        self.assertNotIn('UIBackgroundModes', project)

    def test_pending_intents_deletion_markers_and_one_shot_cloud_request(self):
        store = (ROOT / 'ClipStudio/Services/LANTransferStore.swift').read_text(encoding='utf-8')
        send = store.split('    func send(', 1)[1].split('    func resumeQueue()', 1)[0]
        self.assertIn('LANFiles.pendingSource', send)
        self.assertLess(send.index('try persist()'), send.index('resumeQueue()'))
        decline = store.split('    func decline(', 1)[1].split('    func cloudFallback(', 1)[0]
        self.assertIn('start(id: id)', decline)
        self.assertLess(decline.index('try self.check(stamp)'), decline.index('client.document('))
        self.assertIn('ignoredOffers.contains(offerID)', store)
        self.assertIn('LANLocalState(records: records, pending: pendingSources', store)
        view = (ROOT / 'ClipStudio/Features/RelayView.swift').read_text(encoding='utf-8')
        task = view.split('let automaticFID = initialUploadFID', 1)[1].split('}.refreshable', 1)[0]
        self.assertLess(task.index('onInitialUploadHandled(fid)'), task.index('await load()'))

    def test_received_files_have_independent_storage_and_protection(self):
        text = (ROOT / 'ClipStudio/Services/LANFiles.swift').read_text(encoding='utf-8')
        self.assertIn('FileProtectionType.complete', text)
        self.assertIn('isExcludedFromBackup = true', text)
        self.assertIn('try output.synchronize()', text)
        self.assertIn('FileManager.default.moveItem(at: partial, to: final)', text)
        view = (ROOT / 'ClipStudio/Features/LANTransferView.swift').read_text(encoding='utf-8')
        self.assertNotIn('cleanupExport()', view)


if __name__ == '__main__':
    result = unittest.main(exit=False)
    print('Synthetic protocol vectors and source boundaries only; run native XCTest and cross-device acceptance separately.')
    sys.exit(not result.result.wasSuccessful())
