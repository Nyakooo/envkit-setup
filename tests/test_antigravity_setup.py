"""Exercise official App selection and user-local installation without network access."""
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

TEXT = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()
CODE = TEXT.split("<<'PYAPP'\n", 1)[1].split('\nPYAPP', 1)[0]
FUNCTIONS = TEXT.split('\n# Single execution entry point.', 1)[0]
BASE = 'https://storage.googleapis.com/antigravity-public/antigravity-hub/2.8.0-123/'


def page():
    return ''.join(f'<a href="{BASE}linux-{arch}/Antigravity.tar.gz">Download</a>'
                   for arch in ('x64', 'arm'))


class AntigravityTests(unittest.TestCase):
    def test_architecture_selection_and_untrusted_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'download.html'
            path.write_text(page().replace("2.8.0-123", "2.7.9-123") + page())
            for arch, target in [('amd64', 'x64'), ('arm64', 'arm')]:
                result = subprocess.run(['python3', '-c', CODE, str(path), arch], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [BASE + f'linux-{target}/Antigravity.tar.gz'])
            for invalid in [page().replace('storage.googleapis.com', 'example.com'),
                            page().replace('Antigravity.tar', 'Other.tar'), 'no downloads']:
                path.write_text(invalid)
                result = subprocess.run(['python3', '-c', CODE, str(path), 'amd64'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def test_install_and_rerun_skip_using_app_version(self):
        self.check_install()

    def test_update_with_missing_old_icon(self):
        self.check_install(updating=True)

    def test_invalid_new_icon_preserves_old_launcher(self):
        self.check_install(updating=True, valid_icon=False)

    def check_install(self, updating=False, valid_icon=True):
        with tempfile.TemporaryDirectory(prefix='antigravity test ') as tmp:
            root = Path(tmp)
            app = root / 'fixture/Antigravity-x64'
            app.mkdir(parents=True)
            png = b'\x89PNG\r\n\x1a\n'
            if valid_icon:
                metadata = json.dumps({'files': {'icon.png': {'offset': '0', 'size': len(png)}}}).encode()
                (app / 'resources').mkdir()
                (app / 'resources/app.asar').write_bytes(
                    struct.pack('<4I', 4, len(metadata) + 8, len(metadata) + 4, len(metadata)) + metadata + png
                )
            launcher = root / 'home/.local/bin/antigravity'
            old_binary = root / 'home/.local/opt/old/antigravity'
            if updating:
                old_binary.parent.mkdir(parents=True)
                old_binary.touch()
                (old_binary.parent / '.envkit-version').write_text('2.7.0\n')
                launcher.parent.mkdir(parents=True)
                launcher.symlink_to(old_binary)
            binary = app / 'antigravity'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            with tarfile.open(root / 'fixture.tar.gz', 'w:gz') as archive:
                archive.add(app, arcname=app.name)
            (root / 'download.html').write_text(page())
            (root / 'work').mkdir()
            (root / 'state').mkdir()
            code = FUNCTIONS + '''
trap - EXIT
HOME="$1/home"; TMP="$1/work"; STATE="$1/state"; ARCH=amd64
FIXTURE="$1"
curl() {
  case " $* " in
    *" https://antigravity.google/download/ "*)
      case " $* " in *" --compressed "*) ;; *) return 99 ;; esac
      for argument do destination="$argument"; done
      cp "$FIXTURE/download.html" "$destination"
      return
      ;;
  esac
  echo LARGE_DOWNLOAD
  for argument do destination="$argument"; done
  cp "$FIXTURE/fixture.tar.gz" "$destination"
}
antigravity_sandbox() { echo SANDBOX_REPAIR; }
antigravity_app || exit 1
antigravity_app
'''
            script = Path(tmp) / 'test.sh'
            script.write_text(code)
            result = subprocess.run(['sh', str(script), tmp], input='\n', capture_output=True, text=True)
            if not valid_icon:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(launcher.resolve(), old_binary)
                self.assertFalse((root / 'home/.local/opt/antigravity-app-2.8.0').exists())
                return
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            prompt = '是否更新？ [Y/n]' if updating else '是否安装 2.8.0？ [Y/n]'
            self.assertIn(prompt, result.stdout)
            self.assertEqual((launcher.resolve().parent / 'icon.png').read_bytes(), png)
            self.assertEqual(result.stdout.count('LARGE_DOWNLOAD'), 1)
            self.assertEqual(result.stdout.count('SANDBOX_REPAIR'), 1)
            self.assertIn('本地 2.8.0 已是最新版', result.stdout)
            self.assertTrue((root / 'home/.local/bin/antigravity').is_file())
            desktop = (root / 'home/.local/share/applications/antigravity-app.desktop').read_text()
            self.assertIn(f'Exec="{root}/home/.local/bin/antigravity" %F', desktop)
            self.assertIn(f'Icon={root}/home/.local/opt/antigravity-app-2.8.0/icon.png', desktop)
            self.assertEqual((root / 'state/versions.log').read_text(), 'antigravity-app 2.8.0\n')

    def test_update_declined_preserves_existing_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / '.local/opt/old'
            app.mkdir(parents=True)
            (app / 'antigravity').touch()
            (app / 'icon.png').touch()
            (root / '.local/share/applications').mkdir(parents=True)
            (app / '.envkit-version').write_text('2.7.0\n')
            (root / '.local/bin').mkdir()
            (root / '.local/bin/antigravity').symlink_to(app / 'antigravity')
            (root / 'download.html').write_text(page())
            code = FUNCTIONS + '''
trap - EXIT
HOME="$1"; TMP="$1"; ARCH=amd64
download() { cp "$TMP/download.html" "$2"; }
curl() { echo UNEXPECTED_DOWNLOAD; return 99; }
antigravity_sandbox() { echo SANDBOX_REPAIR; }
antigravity_app
'''
            script = Path(tmp) / 'test.sh'
            script.write_text(code)
            result = subprocess.run(['sh', str(script), tmp], input='n\n', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('UNEXPECTED_DOWNLOAD', result.stdout)
            self.assertEqual((root / '.local/bin/antigravity').resolve(), app / 'antigravity')

    def test_sandbox_profile_validated_installed_and_loaded(self):
        with tempfile.TemporaryDirectory(prefix='antigravity sandbox ') as tmp:
            root = Path(tmp)
            app = root / 'app'
            app.mkdir()
            binary = app / 'antigravity'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            code = FUNCTIONS + '''
trap - EXIT
TMP="$1"
sysctl() { echo 1; }
apparmor_parser() { :; }
sudo() { printf '%s\\n' "$*" >> "$TMP/sudo.log"; }
antigravity_sandbox "$TMP/app"
'''
            script = Path(tmp) / 'test.sh'
            script.write_text(code)
            result = subprocess.run(['sh', str(script), tmp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            profile = (root / 'antigravity-apparmor').read_text()
            self.assertIn(f'"{binary}" flags=(unconfined)', profile)
            self.assertIn('  userns,', profile)
            calls = (root / 'sudo.log').read_text().splitlines()
            self.assertEqual(len(calls), 3)
            self.assertTrue(calls[0].startswith('apparmor_parser -Q -T '))
            self.assertTrue(calls[1].startswith('install -m 0644 '))
            self.assertTrue(calls[2].startswith('apparmor_parser -r /etc/apparmor.d/ubuntu-init-antigravity-'))
