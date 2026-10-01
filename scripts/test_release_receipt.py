import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('release_receipt.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReceiptTests(unittest.TestCase):
    def test_identity_comes_from_binary_and_digest_changes_with_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / 'app.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/App.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'example.app', 'CFBundleShortVersionString': '2.0', 'CFBundleVersion': '280'}))
            first = module.receipt(ipa, 'source')
            self.assertEqual(first['identity']['CFBundleVersion'], '280')
            with zipfile.ZipFile(ipa, 'a') as archive:
                archive.writestr('Payload/App.app/extra', b'changed')
            self.assertNotEqual(first['sha256'], module.receipt(ipa, 'source')['sha256'])

    def test_refuses_missing_app_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / 'app.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('junk', '')
            with self.assertRaises(ValueError):
                module.receipt(ipa, 'source')

if __name__ == '__main__': unittest.main()
