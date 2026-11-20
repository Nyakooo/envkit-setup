"""Real zsh startup using an isolated HOME; no login-shell mutations."""
import os
import pty
import select
import shlex
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

FUNCTIONS = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split('\n# Single execution entry point.', 1)[0]


class ZshSetupTests(unittest.TestCase):
    def test_finish_enters_interactive_zsh_and_loads_aliases(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.zshrc').write_text("alias ter='print -r -- TER_READY'\neval ter\nexit 0\n")
            temp = home / 'installer-tmp'
            temp.mkdir()
            env = dict(os.environ, HOME=tmp, ZDOTDIR=tmp)
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen(
                    ['sh', '-c', FUNCTIONS + '\nTMP="$HOME/installer-tmp"; enter_configured_zsh\n'],
                    env=env, stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                slave = None
                process.wait(timeout=10)
                output = b''
                while select.select([master], [], [], 0.2)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                self.assertEqual(process.returncode, 0, output.decode(errors='replace'))
                self.assertIn(b'TER_READY', output)
                self.assertFalse(temp.exists())
            finally:
                os.close(master)
                if slave is not None:
                    os.close(slave)
                if 'process' in locals() and process.poll() is None:
                    process.kill()
                    process.wait()

    def test_finish_refreshes_groups_as_same_user_without_sg(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.zshrc').write_text("alias ter='print -r -- TER_READY'\neval ter\nexit 0\n")
            temp = home / 'installer-tmp'
            temp.mkdir()
            env = dict(os.environ, HOME=tmp, ZDOTDIR=tmp)
            sudo_stub = home / 'sudo'
            sudo_stub.write_text('#!/bin/sh\n[ "$1" = -u ] && [ "$2" = "$(id -un)" ] && [ "$3" = -- ] || exit 99\nshift 3\nprintf "GROUP_REFRESH_OK\\n"\nexec "$@"\n')
            sudo_stub.chmod(0o755)
            env['PATH'] = tmp + os.pathsep + env['PATH']
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen(
                    ['sh', '-c', FUNCTIONS + '\nDOCKER_GROUP_REFRESH=yes; TMP="$HOME/installer-tmp"; enter_configured_zsh\n'],
                    env=env, stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                slave = None
                process.wait(timeout=10)
                output = b''
                while select.select([master], [], [], 0.2)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                self.assertEqual(process.returncode, 0, output.decode(errors='replace'))
                self.assertIn(b'TER_READY', output)
                self.assertIn(b'GROUP_REFRESH_OK', output)
                self.assertFalse(temp.exists())
            finally:
                os.close(master)
                if slave is not None:
                    os.close(slave)
                if 'process' in locals() and process.poll() is None:
                    process.kill()
                    process.wait()

    def test_official_template_and_migration_preserve_comments_and_user_content(self):
        for previous in [None, '# BEGIN ubuntu-init zsh\nZSH_THEME=funky\nalias ra=ranger\n# END ubuntu-init zsh\nexport MY_SETTING=keep\n']:
            with self.subTest(previous=previous), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp)
                template = home / '.oh-my-zsh/templates/zshrc.zsh-template'
                template.parent.mkdir(parents=True)
                original = '# Official template comments\n# Theme selection documentation\nZSH_THEME="robbyrussell"\nplugins=(git)\n'
                template.write_text(original)
                if previous is not None:
                    (home / '.zshrc').write_text(previous)
                env = dict(os.environ, HOME=tmp)
                env.pop('ZDOTDIR', None)
                result = subprocess.run(['sh', '-c', FUNCTIONS + '\nmkdir -p "$STATE"\nzsh_configure\nzsh_configure'], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                actual = (home / '.zshrc').read_text()
                self.assertTrue(actual.startswith(original))
                self.assertEqual(actual.count('# Official template comments'), 1)
                self.assertNotIn('funky', actual)
                self.assertNotIn('alias ra', actual)
                if previous is not None:
                    self.assertIn('export MY_SETTING=keep', actual)

    def test_existing_user_configuration_is_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            template = home / '.oh-my-zsh/templates/zshrc.zsh-template'
            template.parent.mkdir(parents=True)
            template.write_text('# official template\n')
            original = '# User comments\nexport MY_SETTING=keep\n'
            (home / '.zshrc').write_text(original)
            env = dict(os.environ, HOME=tmp)
            env.pop('ZDOTDIR', None)
            result = subprocess.run(['sh', '-c', FUNCTIONS + '\nzsh_configure'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((home / '.zshrc').read_text(), original)

    def test_official_installer_network_failure_never_changes_shell_or_creates_custom_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            env.pop('ZDOTDIR', None)
            code = FUNCTIONS + '''
TMP="$HOME/tmp"; mkdir -p "$TMP" "$STATE"
download() { return 1; }
chsh() { echo unexpected-chsh; return 99; }
if zsh_setup; then exit 98; fi
[ ! -f "$HOME/.zshrc" ]
'''
            result = subprocess.run(['sh', '-c', code], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('unexpected-chsh', result.stdout)

    def test_official_install_then_plugin_download_then_customization(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            env.pop('ZDOTDIR', None)
            code = FUNCTIONS + r'''
TMP="$HOME/tmp"; mkdir -p "$TMP" "$STATE"
download() {
 [ "$1" = https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh ] || return 1
 cat > "$2" <<'INSTALL'
[ "$RUNZSH" = no ] && [ "$CHSH" = no ] && [ "$KEEP_ZSHRC" = yes ] || exit 98
mkdir -p "$ZSH/templates" "$ZSH/themes"
touch "$ZSH/themes/funky.zsh-theme"
printf '# Official comments\nexport ZSH="$HOME/.oh-my-zsh"\nZSH_THEME="robbyrussell"\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh\n' > "$ZSH/templates/zshrc.zsh-template"
touch "$ZSH/oh-my-zsh.sh"
cp "$ZSH/templates/zshrc.zsh-template" "$HOME/.zshrc"
INSTALL
}
git_update() {
 [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] || return 98
 grep -q 'ZSH_THEME="robbyrussell"' "$HOME/.zshrc" || return 97
 ! grep -q 'plugins+=' "$HOME/.zshrc" || return 96
 mkdir -p "$1"
 name=${1##*/}
 touch "$1/$name.plugin.zsh"
}
getent() { printf 'test:x:1000:1000::%s:%s\n' "$HOME" "$(command -v zsh)"; }
refresh_zsh_env() { :; }
zsh_setup
grep -q '# Official comments' "$HOME/.zshrc"
grep -q 'ZSH_THEME="funky"' "$HOME/.zshrc"
zsh_customize
zsh -f -c 'source "$HOME/.zshrc"; [[ "$ZSH_THEME" = funky && "${aliases[ra]}" = ranger && "${(j: :)plugins}" = "git zsh-autosuggestions zsh-syntax-highlighting" ]]'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho before-update\n' > "$HOME/.local/bin/termihomo"
chmod +x "$HOME/.local/bin/termihomo"
zsh -f -c 'source "$HOME/.zshrc"; eval ter' | grep -qx before-update
printf '#!/bin/sh\necho after-update\n' > "$HOME/.local/bin/termihomo"
zsh -f -c 'source "$HOME/.zshrc"; eval ter' | grep -qx after-update
[ "$(grep -c '^# BEGIN ubuntu-init shell extras' "$HOME/.zshrc")" -eq 1 ]
'''
            result = subprocess.run(['sh', '-c', code], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('UNEXPECTED_GIT', result.stdout)

    def test_missing_plugin_never_writes_customization(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.oh-my-zsh/themes').mkdir(parents=True)
            (home / '.oh-my-zsh/themes/funky.zsh-theme').touch()
            original = '# Original comments\nZSH_THEME="robbyrussell"\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh\n'
            (home / '.zshrc').write_text(original)
            env = dict(os.environ, HOME=tmp)
            env.pop('ZDOTDIR', None)
            result = subprocess.run(['sh', '-c', FUNCTIONS + '\nif zsh_customize; then exit 99; fi'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((home / '.zshrc').read_text(), original)

    def test_source_custom_zshrc_updates_parent_installer_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zdot = root / 'zsh config'
            zdot.mkdir()
            (zdot / '.zshrc').write_text('export PATH="$HOME/node bin:$PATH"\nexport NVM_DIR="$HOME/nvm path"\n')
            old_proxy = '# BEGIN ubuntu-init proxy\nexport http_proxy=http://127.0.0.1:9999\n# END ubuntu-init proxy\n'
            with (zdot / '.zshrc').open('a') as stream:
                stream.write(old_proxy)
            (root / '.profile').write_text('export KEEP_ME=yes\n' + old_proxy)
            env = dict(os.environ, HOME=tmp, ZDOTDIR=str(zdot))
            code = FUNCTIONS + '''
TMP="$1"; trap - EXIT
STATE="$HOME/state"; mkdir -p "$STATE"
export http_proxy=http://127.0.0.1:18080
zsh_configure
cleanup_legacy_proxy_env
[ "$NVM_DIR" = "$HOME/nvm path" ]
[ "$http_proxy" = http://127.0.0.1:18080 ]
case "$PATH" in "$HOME/node bin:"*) ;; *) exit 97 ;; esac
[ ! -e "$HOME/.zshrc" ]
'''
            result = subprocess.run(['sh', '-c', code, 'test', tmp], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('ubuntu-init proxy', (zdot / '.zshrc').read_text())
            self.assertNotIn('ubuntu-init proxy', (root / '.profile').read_text())
            self.assertIn('KEEP_ME=yes', (root / '.profile').read_text())

    def test_nested_zsh_does_not_suspend_foreground_installer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.zshrc').write_text('export ZSH_THEME=funky\nexport ZSH_CACHE_DIR="$HOME/cache"\n')
            script = root / 'installer.sh'
            script.write_text(FUNCTIONS + '''
TMP="$HOME/tmp"; mkdir -p "$TMP"
refresh_zsh_env
validate_zsh_startup
printf 'KEYBOARD_NEXT\\nTRAE_NEXT\\n'
''')
            pid, fd = pty.fork()
            if pid == 0:
                os.environ['HOME'] = tmp
                os.environ.pop('ZDOTDIR', None)
                os.execvp('zsh', ['zsh', '-f'])
            output = b''
            try:
                command = 'sh ' + shlex.quote(str(script)) + '; printf "__INSTALLER_EXIT=%s\\n" $?\n'
                os.write(fd, command.encode())
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if not select.select([fd], [], [], 0.2)[0]:
                        continue
                    try:
                        block = os.read(fd, 65536)
                    except OSError:
                        break
                    if not block:
                        break
                    output += block
                    if b'__INSTALLER_EXIT=0\r\n' in output or b'suspended (tty input)' in output:
                        break
            finally:
                try:
                    os.kill(pid, signal.SIGHUP)
                except ProcessLookupError:
                    pass
                os.close(fd)
                os.waitpid(pid, 0)
            text = output.decode(errors='replace')
            self.assertNotIn('suspended (tty input)', text)
            self.assertIn('__INSTALLER_EXIT=0', text)
            self.assertIn('KEYBOARD_NEXT', text)
            self.assertIn('TRAE_NEXT', text)


if __name__ == '__main__':
    unittest.main()
