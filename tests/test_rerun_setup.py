"""Repeat real configuration paths with isolated files and service stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-ubuntu.sh'
FUNCTIONS = SCRIPT.read_text().split('\n# Single execution entry point.', 1)[0]


class RerunTests(unittest.TestCase):
    def shell(self, home, code):
        env = dict(os.environ, HOME=str(home), PATH=str(home / 'bin') + ':' + os.environ['PATH'])
        env.pop('ZDOTDIR', None)
        result = subprocess.run(['sh', '-c', FUNCTIONS + '''
trap - EXIT
TMP="$HOME/tmp"; mkdir -p "$TMP" "$STATE"
STEP_EVENTS="$TMP/events"; export STEP_EVENTS
refresh_zsh_env() { :; }
''' + code], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_vim_zsh_and_proxy_files_unchanged_then_missing_config_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.oh-my-zsh/themes').mkdir(parents=True)
            (home / '.oh-my-zsh/themes/funky.zsh-theme').touch()
            for name in ['zsh-autosuggestions', 'zsh-syntax-highlighting']:
                plugin = home / '.oh-my-zsh/custom/plugins' / name
                plugin.mkdir(parents=True)
                (plugin / (name + '.plugin.zsh')).touch()
            (home / '.zshrc').write_text('ZSH_THEME="robbyrussell"\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh\n')
            (home / '.profile').write_text('export KEEP_ME=yes\n')
            command = 'vim_setup\nzsh_customize\ncleanup_legacy_proxy_env\n'
            self.shell(home, command)
            files = [home / name for name in ['.vimrc', '.zshrc', '.profile']]
            before = [(p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino) for p in files]
            self.shell(home, command)
            self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino) for p in files])
            (home / '.vimrc').unlink()
            self.shell(home, 'vim_setup\n')
            self.assertEqual((home / '.vimrc').read_bytes(), before[0][0])

    def test_vicinae_skips_restart_but_handles_updates_and_stopped_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            binary = home / '.local/bin/vicinae'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            mockbin = home / 'bin'
            mockbin.mkdir()
            for name in ['update-desktop-database', 'xdg-mime']:
                mock = mockbin / name
                mock.write_text('#!/bin/sh\nexit 0\n')
                mock.chmod(0o755)
            stubs = r'''
systemctl() {
 printf '%s\n' "$*" >> "$TMP/services"
 case "$2" in
 is-active) [ ! -f "$TMP/stopped" ] ;;
 start) rm -f "$TMP/stopped" ;;
 *) return 0 ;;
 esac
}
'''
            self.shell(home, stubs + 'launcher_service_setup no\n')
            runtime = home / '.config/systemd/user/vicinae.service.d/runtime.conf'
            before = (runtime.read_bytes(), runtime.stat().st_mtime_ns)
            log = home / 'tmp/services'
            log.write_text('')
            self.shell(home, stubs + 'launcher_service_setup no\n')
            self.assertEqual(before, (runtime.read_bytes(), runtime.stat().st_mtime_ns))
            self.assertNotIn('restart', log.read_text())
            self.assertNotIn('daemon-reload', log.read_text())
            self.shell(home, stubs + 'launcher_service_setup yes\n')
            self.assertIn('restart vicinae.service', log.read_text())
            log.write_text('')
            (home / 'tmp/stopped').touch()
            self.shell(home, stubs + 'launcher_service_setup no\n')
            self.assertIn('start vicinae.service', log.read_text())
            self.assertNotIn('restart', log.read_text())
            runtime.unlink()
            log.write_text('')
            self.shell(home, stubs + 'launcher_service_setup no\n')
            self.assertIn('daemon-reload', log.read_text())
            self.assertIn('restart vicinae.service', log.read_text())

    def test_monitor_format_skips_matching_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            module = home / '.local/share/indicator-sysmonitor/sysmonitor_common/sensors.py'
            module.parent.mkdir(parents=True)
            module.write_text('class CpuTemperatureSensor: pass\n')
            config = home / '.config/indicator-sysmonitor/settings.json'
            config.parent.mkdir(parents=True)
            config.write_text('{"custom_text":"old","custom_setting":true}\n')
            self.shell(home, 'sysmonitor_format\n')
            before = (config.read_bytes(), config.stat().st_mtime_ns)
            self.shell(home, 'sysmonitor_format\n')
            self.assertEqual(before, (config.read_bytes(), config.stat().st_mtime_ns))
            self.assertIn('"custom_setting": true', config.read_text())


if __name__ == '__main__':
    unittest.main()
