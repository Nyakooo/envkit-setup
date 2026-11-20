"""Exercise the keyboard installer with isolated files and stubbed host services."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-ubuntu.sh'


class KeyboardSetupTests(unittest.TestCase):
    def run_setup(self, path, extra='', *, codename='resolute', candidate='2.5.0', failure='', packaged_binary=False):
        source = SCRIPT.read_text().split('\n# Single execution entry point.', 1)[0]
        source = source.replace('/etc/keyd', str(path / 'keyd'))
        binary = path / 'bin/keyd.rvaiya'
        source = source.replace('/usr/bin/keyd.rvaiya', str(binary))
        if packaged_binary:
            binary.parent.mkdir()
            import shlex
            binary.write_text('#!/bin/sh\nprintf "keyd.rvaiya %s\\n" "$*" >> '
                              + shlex.quote(str(path / 'calls')) + '\n')
            binary.chmod(0o755)
        stub = r'''
TMP="$1"; STATE="$TMP/state"; DE=gnome; DESKTOP=GNOME
DBUS_SESSION_BUS_ADDRESS=test
cleanup() { :; }
mkdir -p "$STATE"
apt() {
 printf 'apt %s\n' "$*" >> "$TMP/calls"
 if [ "$FAILURE" = upgrade ]; then printf '2.5.1' > "$TMP/version"; fi
}
installed_package_version() { if [ -f "$TMP/version" ]; then cat "$TMP/version"; else printf '2.5.0'; fi; }
apt_update() { echo apt-update >> "$TMP/calls"; }
candidate_package_version() { printf '%s\n' "$CANDIDATE"; }
sudo() {
 if [ "$1" = add-apt-repository ]; then
  shift; printf 'ppa %s\n' "$*" >> "$TMP/calls"
 else
  "$@"
 fi
}
systemctl() {
 printf 'systemctl %s\n' "$*" >> "$TMP/calls"
 [ "$FAILURE" != service ] || return 1
 case "$1" in
 is-enabled) [ ! -f "$TMP/disabled" ] ;;
 is-active) [ ! -f "$TMP/stopped" ] ;;
 enable) rm -f "$TMP/disabled" "$TMP/stopped" ;;
 esac
}
keyd() {
 printf 'keyd %s\n' "$*" >> "$TMP/calls"
 [ "$FAILURE" != reload ]
}
gsettings() {
 case "$1" in
 writable) echo true ;;
 get) cat "$TMP/options" ;;
 set)
  printf 'gsettings set %s\n' "$4" >> "$TMP/calls"
  [ "$FAILURE" = readback ] || printf '%s' "$4" > "$TMP/options"
  ;;
 *) return 1 ;;
 esac
}
# dconf must not be called by the keyboard step.
dconf() { echo unexpected-dconf >> "$TMP/calls"; return 99; }
keyboard_setup
''' + extra
        result = subprocess.run(['sh', '-c', source + '\n' + stub, 'test', str(path)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                env=dict(os.environ, CODENAME=codename, CANDIDATE=candidate,
                                         FAILURE=failure))
        return result

    def test_keyd_migrates_both_old_modes_and_reruns_without_input(self):
        import ast
        import json
        for mode in ['local', 'upstream']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                state = path / 'state'
                state.mkdir()
                (state / 'keyboard-remap-mode').write_text(mode)
                (state / 'keyboard-dconf-editor-migrated').touch()
                original = ['caps:swapescape', 'ctrl:swapcaps', 'compose:caps',
                            'grp:alt_shift_toggle']
                (path / 'options').write_text(repr(original))
                result = self.run_setup(path, '\nkeyboard_setup </dev/null\n')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(ast.literal_eval((path / 'options').read_text()),
                                 ['grp:alt_shift_toggle'])
                self.assertEqual(json.loads((state / 'desktop-backup/keyboard-before-keyd.json').read_text()),
                                 original)
                config = (path / 'keyd/ubuntu-init.conf').read_text()
                self.assertIn('capslock = esc', config)
                self.assertIn('esc = capslock', config)
                self.assertEqual(config, '# ubuntu-init Caps/Esc swap\n[ids]\n*\n\n[main]\ncapslock = esc\nesc = capslock\n')
                calls = (path / 'calls').read_text()
                self.assertIn('apt install -y --no-install-recommends keyd', calls)
                self.assertEqual(calls.count('keyd reload'), 1)
                self.assertEqual(calls.count('apt install -y --no-install-recommends keyd'), 2)
                self.assertIn('跳过写入和重载', result.stdout)
                self.assertIn('systemctl is-active --quiet keyd', calls)
                self.assertNotIn('dconf', calls)
                self.assertNotIn('ppa', calls)
                self.assertFalse((state / 'keyboard-remap-mode').exists())
                self.assertFalse((state / 'keyboard-dconf-editor-migrated').exists())

    def test_ubuntu_packaged_binary_is_used_for_reload(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'options').write_text('@as []')
            # Leave the generic keyd stub failing to catch use of the wrong name.
            result = self.run_setup(path, packaged_binary=True, failure='reload')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = (path / 'calls').read_text()
            self.assertIn('keyd.rvaiya reload', calls)
            self.assertNotIn('keyd reload', calls)
            self.assertTrue((path / 'keyd/ubuntu-init.conf').exists())

    def test_keyd_update_and_service_repair_are_not_skipped(self):
        scenarios = ['FAILURE=upgrade', 'touch "$TMP/stopped"', 'touch "$TMP/disabled"']
        for setup in scenarios:
            with self.subTest(setup=setup), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                (path / 'options').write_text('@as []')
                result = self.run_setup(path, '\n' + setup + '\nkeyboard_setup\n')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = (path / 'calls').read_text()
                self.assertEqual(calls.count('keyd reload'), 2)
                self.assertEqual(calls.count('apt install -y --no-install-recommends keyd'), 2)

    def test_noble_adds_upstream_ppa_only_when_package_unavailable(self):
        for candidate in ['(none)', '2.5.0']:
            with self.subTest(candidate=candidate), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                (path / 'options').write_text('@as []')
                result = self.run_setup(path, codename='noble', candidate=candidate)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = (path / 'calls').read_text()
                self.assertEqual('ppa -y ppa:keyd-team/ppa' in calls, candidate == '(none)')
                if candidate == '(none)':
                    self.assertLess(calls.index('apt-update'), calls.index('apt install -y --no-install-recommends keyd'))

    def test_existing_user_keyd_config_is_preserved_before_xkb_change(self):
        for name in ['default.conf', 'ubuntu-init.conf']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                root = path / 'keyd'
                root.mkdir()
                custom = '[ids]\n*\n[main]\na = b\n'
                (root / name).write_text(custom)
                (path / 'options').write_text("['caps:swapescape']")
                result = self.run_setup(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((root / name).read_text(), custom)
                self.assertEqual((path / 'options').read_text(), "['caps:swapescape']")
                self.assertNotIn('gsettings set', (path / 'calls').read_text())

    def test_failed_activation_restores_original_xkb_and_keyd_config(self):
        for failure in ['service', 'reload', 'readback']:
            for existing in [False, True]:
                with self.subTest(failure=failure, existing=existing), tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp)
                    config = path / 'keyd/ubuntu-init.conf'
                    previous = '# ubuntu-init Caps/Esc swap\n[ids]\n*\n[main]\ncapslock = esc\nesc = capslock\n# prior version\n'
                    if existing:
                        config.parent.mkdir()
                        config.write_text(previous)
                    (path / 'options').write_text("['caps:swapescape']")
                    result = self.run_setup(path, failure=failure)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('恢复本次运行前的键位', result.stderr)
                    self.assertEqual((path / 'options').read_text(), "['caps:swapescape']")
                    if existing:
                        self.assertEqual(config.read_text(), previous)
                    else:
                        self.assertFalse(config.exists())

    def test_shell_backup_uses_gio_and_keeps_first_snapshot(self):
        source = SCRIPT.read_text()
        code = source.split("<<'PYSHELLBACKUP'\n", 1)[1].split('\nPYSHELLBACKUP', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            check = "from gi.repository import Gio\nsettings = Gio.Settings.new('org.gnome.shell')\n"
            check += "settings.set_strv('enabled-extensions', ['original@example'])\n"
            check += code + "\noriginal = backup.read_text()\n"
            check += "settings.set_strv('enabled-extensions', ['changed@example'])\n"
            check += code + "\nassert backup.read_text() == original\n"
            check += "assert json.loads(original)['enabled-extensions'] == settings.get_value('enabled-extensions').new_strv(['original@example']).print_(True)\n"
            result = subprocess.run(['/usr/bin/python3', '-c', check, tmp],
                                    env=dict(os.environ, GSETTINGS_BACKEND='memory'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('dconf dump', source)
        self.assertNotIn('dconf-cli', source)

    def test_single_entry_runs_all_software_without_install_questions(self):
        text = SCRIPT.read_text()
        functions, dispatch = text.split('\n# Single execution entry point.', 1)
        stub = """
preflight() {
 STATE=$(mktemp -d)
 printf 'FlClash\\n' > "$STATE/proxy-tool"
}
configure_proxy() { :; }
set_mirror() { :; }
apt_update() { :; }
apt() { :; }
proxy_setup() { :; }
zsh_configure() { :; }
cleanup_legacy_proxy_env() { :; }
optional() { printf 'STEP:%s\\n' "$1"; }
chsh() { :; }
"""
        result = subprocess.run(['sh', '-c', functions + '\n' + stub + '\n' + dispatch,
                                 'test'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for label in ['家目录标准文件夹英文名称', 'Caps/Esc 互换（keyd）', 'Remmina/scrcpy/VLC', 'WowType 输入法']:
            self.assertIn('STEP:' + label, result.stdout)
        self.assertNotIn('yes_no', functions)
        self.assertNotIn('--desktop-only', dispatch)

    def test_legacy_automatic_mapping_removed(self):
        source = SCRIPT.read_text()
        self.assertNotIn('apply_xkb_session()', source)
        self.assertNotIn("['setxkbmap'", source)
        self.assertNotIn('gnome_settings()', source)


if __name__ == '__main__':
    unittest.main()
