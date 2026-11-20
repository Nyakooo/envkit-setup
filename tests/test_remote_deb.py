"""Run real deb metadata parsing with mocked transport and package installation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split('\n# Single execution entry point.', 1)[0]


class RemoteDebTests(unittest.TestCase):
    def run_case(self, current, answer='', fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            control = root / 'package/DEBIAN'
            control.mkdir(parents=True)
            (control / 'control').write_text('Package: example-app\nVersion: 2.0\nArchitecture: amd64\nMaintainer: Test <test@example.com>\nDescription: fixture\n')
            subprocess.run(['dpkg-deb', '--build', str(root / 'package'), str(root / 'fixture.deb')], check=True, capture_output=True)
            code = '''
TMP="$1"; STATE="$TMP/state"; ARCH=amd64
mkdir -p "$STATE"
printf '%s' "$2" > "$TMP/current"
installed_package_version() { cat "$TMP/current"; }
curl() {
 echo "$*" >> "$TMP/requests"
 for last do :; done
 cp "$TMP/fixture.deb" "$last"
}
apt_raw() {
 echo INSTALL >> "$TMP/requests"
 [ "$3" != fail ] || return 1
 printf 2.0 > "$TMP/current"
}
'''
            if fail:
                code += 'apt_raw() { return 1; }\n'
            code += '''
results_init
optional 'Example software' remote_deb_install Example example-app https://example.test/app.deb "$TMP/app.deb"
print_summary
cat "$TMP/requests"
'''
            return subprocess.run(['sh', '-c', SOURCE + '\n' + code, 'test', tmp, current], input=answer, capture_output=True, text=True)

    def test_same_newer_declined_and_eof_never_download_payload(self):
        for version, answer in [('2.0', ''), ('3.0', ''), ('1.0', 'n\n'), ('1.0', '')]:
            with self.subTest(version=version, answer=answer):
                result = self.run_case(version, answer)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('--range 0-1048575', result.stdout)
                self.assertNotIn('INSTALL', result.stdout)
                self.assertNotIn('下载完整安装包', result.stdout)
                self.assertIn('本次已更新：无', result.stdout)

    def test_accepted_upgrade_and_new_install_are_reported(self):
        for version, answer, expected in [('1.0', 'y\n', '本次已更新：Example：1.0 → 2.0'), ('', '', '本次新安装：Example：2.0')]:
            result = self.run_case(version, answer)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('INSTALL', result.stdout)
            self.assertIn(expected, result.stdout)
            self.assertIn('1. [成功] Example software', result.stdout)

    def test_failed_install_is_not_reported_as_completed_update(self):
        result = self.run_case('1.0', 'y\n', fail=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('本次已更新：无', result.stdout)
        self.assertIn('1. [失败] Example software', result.stdout)
