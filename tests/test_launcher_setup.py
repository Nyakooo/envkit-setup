"""Exercise launcher settings without changing the logged-in desktop."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class LauncherTests(unittest.TestCase):
    def test_conflicts_hidden_icons_and_repeat(self):
        text = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()
        start = text.index('# ubuntu-init Copyous/Vicinae configuration')
        code = text[start:text.index('\nPY\n', start)]
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / 'home with spaces'
            for uuid, schema, keys in [
                ('copyous@boerdereinar.dev', 'org.gnome.shell.extensions.copyous',
                 '<key name="indicator-display" type="s"><default>"icon-only"</default></key>'
                 '<key name="open-clipboard-dialog-shortcut" type="as"><default>["&lt;Super&gt;&lt;Shift&gt;v"]</default></key>'),
                ('vicinae@dagimg-dot', 'org.gnome.shell.extensions.vicinae',
                 '<key name="show-status-indicator" type="b"><default>true</default></key>')]:
                directory = home / '.local/share/gnome-shell/extensions' / uuid / 'schemas'
                directory.mkdir(parents=True)
                (directory / 'test.gschema.xml').write_text(
                    f'<schemalist><schema id="{schema}" path="/test/{uuid.split("@")[0]}/">{keys}</schema></schemalist>')
                subprocess.run(['glib-compile-schemas', str(directory)], check=True)
            check = '''
from gi.repository import Gio
wm = Gio.Settings.new('org.gnome.desktop.wm.keybindings')
wm.set_strv('switch-input-source', ['<Super>space', 'XF86Keyboard'])
shell = Gio.Settings.new('org.gnome.shell.keybindings')
shell.set_strv('toggle-message-tray', ['<Super>v', '<Super>m'])
INSTALLER
original = backup.read_text()
INSTALLER
assert not changes
assert backup.read_text() == original
assert wm.get_strv('switch-input-source') == ['XF86Keyboard']
assert shell.get_strv('toggle-message-tray') == ['<Super>m']
assert copyous.get_string('indicator-display') == 'hidden'
assert copyous.get_strv('open-clipboard-dialog-shortcut') == ['<Super>v']
assert not vicinae.get_boolean('show-status-indicator')
assert settings.get_string('binding') == '<Super>space'
assert media.get_strv('custom-keybindings').count(path) == 1
assert 'home with spaces' in settings.get_string('command')
'''.replace('INSTALLER', code)
            result = subprocess.run(['/usr/bin/python3', '-c', check, str(home / 'state')],
                                    env=dict(os.environ, HOME=str(home), GSETTINGS_BACKEND='memory'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

            # Skipped extensions must not be loaded or take over Super+V.
            skipped = """
from gi.repository import Gio
shell = Gio.Settings.new('org.gnome.shell.keybindings')
shell.set_strv('toggle-message-tray', ['<Super>v', '<Super>m'])
INSTALLER
assert shell.get_strv('toggle-message-tray') == ['<Super>v', '<Super>m']
assert settings.get_string('binding') == '<Super>space'
assert 'copyous' not in globals()
assert 'vicinae' not in globals()
""".replace('INSTALLER', code)
            result = subprocess.run(['/usr/bin/python3', '-c', skipped, str(home / 'skipped-state'), '0', '0'],
                                    env=dict(os.environ, HOME=str(home), GSETTINGS_BACKEND='memory'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
