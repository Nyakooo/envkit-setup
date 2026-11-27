"""Exercise official IDE selection and user-local installation without network access."""
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

TEXT = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()
START = TEXT.index('# ubuntu-init Antigravity selection:')
CODE = TEXT[START:TEXT.index('\nPYANTIGRAVITY', START)]
FUNCTIONS = TEXT.split('\n# Single execution entry point.', 1)[0]
BASE = 'https://edgedl.me.gvt1.com/edgedl/release2/abc/antigravity/stable/2.8.0-123/'


def page():
    return ''.join(f'<a href="{BASE}linux-{arch}/Antigravity%20IDE.tar.gz">Download</a>'
                   for arch in ('x64', 'arm'))


class AntigravityTests(unittest.TestCase):
    def test_architecture_selection_and_untrusted_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'download.html'
            path.write_text(page() + page())
            for arch, target in [('amd64', 'x64'), ('arm64', 'arm')]:
                result = subprocess.run(['python3', '-c', CODE, str(path), arch], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ['2.8.0', BASE + f'linux-{target}/Antigravity%20IDE.tar.gz'])
            for invalid in [page().replace('edgedl.me.gvt1.com', 'example.com'),
                            page().replace('Antigravity%20IDE', 'Antigravity'), 'no downloads']:
                path.write_text(invalid)
                result = subprocess.run(['python3', '-c', CODE, str(path), 'amd64'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def test_install_and_rerun_skip_using_ide_version(self):
        with tempfile.TemporaryDirectory(prefix='antigravity test ') as tmp:
            root = Path(tmp)
            app = root / 'fixture/Antigravity IDE'
            (app / 'bin').mkdir(parents=True)
            (app / 'resources/app/resources/linux').mkdir(parents=True)
            (app / 'resources/app/product.json').write_text(json.dumps({'ideVersion': '2.8.0', 'version': '1.107.0'}))
            (app / 'resources/app/resources/linux/code.png').touch()
            for name in ['bin/antigravity-ide', 'antigravity-ide']:
                binary = app / name
                binary.write_text('#!/bin/sh\necho 1.107.0\n')
                binary.chmod(0o755)
            with tarfile.open(root / 'fixture.tar.gz', 'w:gz') as archive:
                archive.add(app, arcname='Antigravity IDE')
            (root / 'download.html').write_text(page())
            (root / 'mock-bin').mkdir()
            updater = root / 'mock-bin/update-desktop-database'
            updater.write_text('#!/bin/sh\nexit 0\n')
            updater.chmod(0o755)
            (root / 'work').mkdir()
            (root / 'state').mkdir()
            code = FUNCTIONS + '''
trap - EXIT
HOME="$1/home"; TMP="$1/work"; STATE="$1/state"; ARCH=amd64
FIXTURE="$1"
PATH="$1/mock-bin:$PATH"
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
antigravity_ide || exit 1
antigravity_ide
'''
            script = Path(tmp) / 'test.sh'
            script.write_text(code)
            result = subprocess.run(['sh', str(script), tmp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count('LARGE_DOWNLOAD'), 1)
            self.assertEqual(result.stdout.count('SANDBOX_REPAIR'), 2)
            self.assertIn('本地 2.8.0 已是最新版', result.stdout)
            self.assertTrue((root / 'home/.local/bin/antigravity-ide').is_file())
            desktop = (root / 'home/.local/share/applications/antigravity-ide.desktop').read_text()
            self.assertIn(f'Exec="{root}/home/.local/opt/antigravity-ide-2.8.0/antigravity-ide" %F', desktop)
            self.assertEqual((root / 'state/versions.log').read_text(), 'antigravity-ide 2.8.0\n')

    def test_update_declined_preserves_existing_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / '.local/opt/old'
            (app / 'bin').mkdir(parents=True)
            (app / 'resources/app').mkdir(parents=True)
            (app / 'bin/antigravity-ide').touch()
            (app / 'resources/app/product.json').write_text('{"ideVersion":"2.7.0"}')
            (root / '.local/bin').mkdir()
            (root / '.local/bin/antigravity-ide').symlink_to(app / 'bin/antigravity-ide')
            (root / 'download.html').write_text(page())
            code = FUNCTIONS + '''
trap - EXIT
HOME="$1"; TMP="$1"; ARCH=amd64
download() { cp "$TMP/download.html" "$2"; }
curl() { echo UNEXPECTED_DOWNLOAD; return 99; }
antigravity_sandbox() { echo SANDBOX_REPAIR; }
antigravity_ide
'''
            script = Path(tmp) / 'test.sh'
            script.write_text(code)
            result = subprocess.run(['sh', str(script), tmp], input='n\n', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('UNEXPECTED_DOWNLOAD', result.stdout)
            self.assertEqual((root / '.local/bin/antigravity-ide').resolve(), app / 'bin/antigravity-ide')

    def test_sandbox_profile_validated_installed_and_loaded(self):
        with tempfile.TemporaryDirectory(prefix='antigravity sandbox ') as tmp:
            root = Path(tmp)
            app = root / 'app'
            app.mkdir()
            binary = app / 'antigravity-ide'
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
