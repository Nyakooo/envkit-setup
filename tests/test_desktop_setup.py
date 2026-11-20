"""Run embedded installers in a temporary HOME; never install packages or change the desktop."""
import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-ubuntu.sh'
TEXT = SCRIPT.read_text()


def payload(marker):
    start = TEXT.index(marker)
    return TEXT[start:TEXT.index('\nPY\n', start)]


class DesktopSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='desktop-test-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home with spaces'
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))

    def python(self, code, *args):
        result = subprocess.run(['/usr/bin/python3', '-c', code, *map(str, args)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_flameshot_shortcuts_preserve_unrelated_bindings_and_backup(self):
        code = payload('# ubuntu-init Flameshot shortcuts:')
        check = r'''
from gi.repository import Gio
from pathlib import Path
import json, subprocess
shell = Gio.Settings.new('org.gnome.shell.keybindings')
shell.set_strv('show-screenshot-ui', ['Print', '<Alt><Control>a', '<Super>Print'])
shell.set_strv('screenshot-window', ['<Alt>Print'])
media = Gio.Settings.new('org.gnome.settings-daemon.plugins.media-keys')
base = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/'
paths = [base + 'terminal/', base + 'old-screenshot/']
media.set_strv('custom-keybindings', paths)
for path, binding in zip(paths, ['<Control><Alt>t', '<Primary><Alt>a']):
    st = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', path)
    st.set_string('binding', binding)
    st.set_string('command', 'original-command')
INSTALLER
backup = Path(__import__('sys').argv[1]) / 'desktop-backup/screenshot-shortcuts.json'
original = backup.read_text()
wrapper_before = (wrapper.read_bytes(), wrapper.stat().st_mtime_ns)
INSTALLER
assert not changed
assert (wrapper.read_bytes(), wrapper.stat().st_mtime_ns) == wrapper_before
assert backup.read_text() == original
assert shell.get_strv('show-screenshot-ui') == ['<Super>Print']
assert shell.get_strv('screenshot-window') == ['<Alt>Print']
registered = media.get_strv('custom-keybindings')
assert len(registered) == len(set(registered)) == 4
for suffix, binding in [('flameshot/', '<Control><Alt>a'), ('flameshot-print/', 'Print'),
                        ('terminal/', '<Control><Alt>t'), ('old-screenshot/', '')]:
    st = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', base + suffix)
    assert st.get_string('binding') == binding
    if suffix.startswith('flameshot'):
        assert 'flameshot-screenshot' in st.get_string('command')
assert json.loads(original)['shell']['show-screenshot-ui'] == ['Print', '<Alt><Control>a', '<Super>Print']
wrapper = Path.home() / '.local/bin/flameshot-screenshot'
subprocess.run(['sh', '-n', str(wrapper)], check=True)
assert 'QT_QPA_PLATFORM=wayland' in wrapper.read_text()
assert not (Path.home() / '.config/autostart').exists()
'''
        check = check.replace('INSTALLER', 'exec(' + repr(code) + ')')
        self.env['GSETTINGS_BACKEND'] = 'memory'
        self.python(check, self.home / 'state')

    def test_wowtype_is_the_only_chinese_input_method_and_enabled_by_default(self):
        root = self.home / '.config/fcitx5'
        root.mkdir(parents=True)
        config = root / 'config'
        config.write_text('[Behavior]\nActiveByDefault=False\nShareInputState=All\n')
        profile = root / 'profile'
        profile.write_text('[Groups/0]\nDefaultIM=pinyin\n[Groups/0/Items/1]\nName=pinyin\n')
        dictionary = root / 'custom-dictionary'
        dictionary.write_text('keep')
        code = payload('# ubuntu-init WowType configuration')
        self.python(code)
        first = (config.read_text(), profile.read_text())
        timestamps = (config.stat().st_mtime_ns, profile.stat().st_mtime_ns)
        self.python(code)
        self.assertEqual(timestamps, (config.stat().st_mtime_ns, profile.stat().st_mtime_ns))
        self.assertEqual(first, (config.read_text(), profile.read_text()))
        settings = configparser.ConfigParser()
        settings.read(config)
        self.assertTrue(settings['Behavior'].getboolean('ActiveByDefault'))
        self.assertEqual(settings['Behavior']['ShareInputState'], 'All')
        methods = configparser.ConfigParser()
        methods.read(profile)
        self.assertEqual(methods['Groups/0']['DefaultIM'], 'wowtype')
        self.assertEqual([methods[group]['Name'] for group in methods if '/Items/' in group],
                         ['keyboard-us', 'wowtype'])
        self.assertEqual(dictionary.read_text(), 'keep')

    def test_monitor_installer_and_sensor_cache(self):
        # Use real upstream source if provided; otherwise a minimal contract fixture.
        upstream = os.environ.get('SYSMONITOR_UPSTREAM')
        stage = Path(self.temp.name) / 'upstream'
        if upstream:
            shutil.copytree(upstream, stage)
        else:
            (stage / 'sysmonitor_common').mkdir(parents=True)
            (stage / 'indicator_sysmonitor').mkdir()
            (stage / 'LICENSE').write_text('fixture')
            (stage / 'sysmonitor_common/sensors.py').write_text(
                "import time\nimport psutil as ps\nfrom gi.repository import GLib\n"
                "def get_default_iface():\n    pass\n"
                "def bytes_to_human(n):\n    return str(n)\n"
                "class BaseSensor:\n    pass\n"
                "class Manager:\n    def __init__(self):\n"
                "            self.sensor_instances = []\n"
                "            for sensor in self.sensor_instances:\n                self.settings = {}\n")
            (stage / 'sysmonitor_common/preferences.py').write_text("ROOT='/usr/share/indicator-sysmonitor'\n")
            (stage / 'indicator_sysmonitor/indicator-sysmonitor').write_text("ROOT='/usr/share/indicator-sysmonitor'\n")
        code = payload('# ubuntu-init monitor installer:')
        self.python(code, stage)
        config = self.home / '.config/indicator-sysmonitor/settings.json'
        data = json.loads(config.read_text())
        data['unrelated'] = 'keep'; config.write_text(json.dumps(data))
        # Reinstall from clean upstream, as the shell installer does.
        if upstream:
            shutil.rmtree(stage); shutil.copytree(upstream, stage)
            self.python(code, stage)
            self.assertEqual(json.loads(config.read_text())['unrelated'], 'keep')
        module = self.home / '.local/share/indicator-sysmonitor/sysmonitor_common/sensors.py'
        test = '''
import importlib.util
from types import SimpleNamespace
from unittest.mock import Mock
from gi.repository import Gio
spec = importlib.util.spec_from_file_location('tested_sensors', __import__('sys').argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
s = m.DesktopTelemetry()
s.bus = Mock()
s.bus.call_sync.return_value.unpack.return_value = ({'/drive': {
    'org.freedesktop.UDisks2.Drive.Ata': {'SmartEnabled': True, 'SmartTemperature': 303.15}}},)
m.ps.sensors_temperatures = lambda: {'coretemp': [SimpleNamespace(current=55)]}
m.ps.sensors_fans = lambda: {'thinkpad': [SimpleNamespace(current=3000)]}
assert m.CpuTemperatureSensor(s).get_value('cpu_temp') == '55°C'
assert m.FanSpeedSensor(s).get_value('fan_rpm') == '3000 RPM'
assert s.bus.call_sync.call_count == 0
assert s.get_value('desktopstats') == 'CPU: 55°C SSD: 30°C FAN: 3000 RPM'
s.get_value('desktopstats'); assert s.bus.call_sync.call_count == 1
m.ps.sensors_temperatures = lambda: {}
m.ps.sensors_fans = lambda: {}
s.next_disk_read = 0
s.bus.call_sync.return_value.unpack.return_value = ({},)
assert m.CpuTemperatureSensor(s).get_value('cpu_temp') == '—'
assert m.FanSpeedSensor(s).get_value('fan_rpm') == '—'
assert s.get_value('desktopstats') == 'CPU: — SSD: — FAN: —'
'''
        self.python(test, module)
        wrapper = self.home / '.local/bin/indicator-sysmonitor'
        subprocess.run(['sh', '-n', str(wrapper)], check=True)
        self.assertTrue(wrapper.stat().st_mode & 0o100)
        self.assertNotIn('/usr/share/indicator-sysmonitor', module.read_text())

    def test_ubuntu_extension_package_branch(self):
        lib = Path(self.temp.name) / 'desktop.sh'
        lib.write_text(TEXT[TEXT.index('backup_user_file() {'):TEXT.index('docker_apt_source() {')])
        for version, package in [('26.04', 'gnome-shell-ubuntu-extensions'),
                                 ('24.04', 'gnome-shell-extension-appindicator')]:
            log = Path(self.temp.name) / ('apt-' + version)
            mockbin = Path(self.temp.name) / 'bin'; mockbin.mkdir(exist_ok=True)
            mock = mockbin / 'gnome-extensions'; mock.write_text('#!/bin/sh\nexit 0\n'); mock.chmod(0o755)
            command = r'''
. "$1"
VERSION_ID="$2"; DE=gnome; TMP="$HOME/tmp"; STATE="$HOME/state"
mkdir -p "$TMP" "$STATE"
apt() { printf '%s\n' "$*" >> "$APT_LOG"; }
git_clone() { :; }
git() { :; }
python3() { :; }
backup_user_file() { :; }

say() { :; }
warn() { :; }
sysmonitor
'''
            subprocess.run(['sh', '-c', command, 'test', str(lib), version],
                           env=dict(self.env, APT_LOG=str(log), PATH=str(mockbin) + ':' + os.environ['PATH']),
                           check=True, capture_output=True)
            self.assertIn(package, log.read_text())
            self.assertIn('gnome-system-monitor', log.read_text())

    def test_all_embedded_python_compiles(self):
        import re
        for i, (_, code) in enumerate(re.findall(r"<<'(PY[A-Z]*)'\n(.*?)\n\1", TEXT, re.S)):
            compile(code, 'embedded-python-' + str(i), 'exec')

    def test_backup_does_not_overwrite_original(self):
        code = TEXT[TEXT.index('backup_user_file() {'):TEXT.index('\nsysmonitor() {')]
        lib = Path(self.temp.name) / 'backup.sh'; lib.write_text(code)
        target = self.home / '.xinputrc'; target.write_text('original')
        command = '. "$1"; STATE="$HOME/state"; backup_user_file "$HOME/.xinputrc"'
        for value in ['original', 'changed']:
            target.write_text(value)
            subprocess.run(['sh', '-c', command, 'test', str(lib)], env=self.env, check=True)
        backup = self.home / 'state/desktop-backup/.xinputrc'
        self.assertEqual(backup.read_text(), 'original')


if __name__ == '__main__':
    unittest.main()
