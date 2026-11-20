"""ChatGPT desktop metadata and skip decisions without installing host packages."""
from pathlib import Path
import subprocess
import tempfile
import unittest

TEXT = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()
START = TEXT.index('# ubuntu-init ChatGPT package selection:')
CODE = TEXT[START:TEXT.index('\nPYCHATGPT', START)]
FUNCTIONS = TEXT.split('\n# Single execution entry point.', 1)[0]


class ChatGptTests(unittest.TestCase):
    def metadata(self, version):
        return ('Package: chatgpt\nVersion: ' + version + '\nArchitecture: amd64\n'
                'Filename: pool/main/c/chatgpt/chatgpt_' + version + '_amd64.deb\nSHA256: ' + 'a' * 64 + '\n\n')

    def test_latest_matching_desktop_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'Packages'
            path.write_text(self.metadata('1.0') + self.metadata('2.0'))
            result = subprocess.run(['python3', '-c', CODE, str(path), 'amd64'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[0], '2.0')
            result = subprocess.run(['python3', '-c', CODE, str(path), 'arm64'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_current_desktop_skips_large_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Packages').write_text(self.metadata('2.0'))
            code = FUNCTIONS + '''
TMP="$1"; ARCH=amd64; trap - EXIT
download() { cp "$TMP/Packages" "$2"; }
installed_package_version() { echo 2.0; }
curl() { echo UNEXPECTED_DOWNLOAD; return 99; }
apt_raw() { return 98; }
chatgpt_desktop
'''
            result = subprocess.run(['sh', '-c', code, 'test', tmp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('已是最新版或更新', result.stdout)
            self.assertNotIn('UNEXPECTED_DOWNLOAD', result.stdout)
