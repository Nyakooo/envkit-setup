"""Version decisions run with mocked package inventory, never host APT writes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-ubuntu.sh'
FUNCTIONS = SCRIPT.read_text().split('\n# Single execution entry point.', 1)[0]


class VersionChecks(unittest.TestCase):
    def run_shell(self, body, answer=''):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['sh', '-c', FUNCTIONS + '\nTMP="$1"\n' + body,
                                     'test', tmp], input=answer, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout + result.stderr

    def test_git_ssh_key_interaction_and_existing_key_skip(self):
        self.run_shell('''
HOME="$TMP/home"; mkdir -p "$HOME/.ssh"
git() { :; }
mkdir -p "$TMP/bin"
PATH="$TMP/bin:$PATH"; export HOME PATH
cat > "$TMP/bin/ssh-keygen" <<'KEYGEN'
#!/bin/sh
  [ "$*" = '-t ed25519 -C user@example.com' ] || exit 1
  IFS= read -r answer
  [ "$answer" = interactive ] || exit 1
  touch "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"
KEYGEN
chmod +x "$TMP/bin/ssh-keygen"
git_ssh_key_setup
printf '#!/bin/sh\\nexit 99\\n' > "$TMP/bin/ssh-keygen"
git_ssh_key_setup
rm "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"
touch "$HOME/.ssh/id_rsa"
git_ssh_key_setup
''', '\n   \nTest User\n\n   \nuser@example.com\ninteractive\nTest User\nuser@example.com\nTest User\nuser@example.com\n')

    def test_git_ssh_key_custom_email(self):
        output = self.run_shell('''
HOME="$TMP/home"; mkdir -p "$HOME/.ssh" "$TMP/bin"
PATH="$TMP/bin:$PATH"; export HOME PATH
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$TMP/bin/ssh-keygen" <<'KEYGEN'
#!/bin/sh
[ "$(git config --global user.name)" = 'Test User' ] || exit 1
[ "$(git config --global user.email)" = custom@example.com ] || exit 1
[ "$#" = 4 ] && [ "$4" = 'custom@example.com' ]
KEYGEN
chmod +x "$TMP/bin/ssh-keygen"
git_ssh_key_setup
[ "$(git config --global user.name)" = 'Test User' ]
[ "$(git config --global user.email)" = custom@example.com ]
''', 'Test User\ncustom@example.com\n')
        self.assertIn('-C "custom@example.com"', output)

    def test_git_ssh_key_eof_does_not_generate_key(self):
        output = self.run_shell("""
HOME="$TMP/home"; mkdir -p "$HOME/.ssh"
export HOME
git() { :; }
mkdir -p "$TMP/bin"
PATH="$TMP/bin:$PATH"; export PATH
printf '#!/bin/sh\\necho unexpected-keygen\\nexit 99\\n' > "$TMP/bin/ssh-keygen"
chmod +x "$TMP/bin/ssh-keygen"
if git_ssh_key_setup; then exit 10; else [ "$?" = 1 ]; fi
""", 'Test User\n')
        self.assertIn('无法读取邮箱', output)
        self.assertNotIn('unexpected-keygen', output)

    def test_git_config_failure_stops_key_generation(self):
        for failed_key in ('user.name', 'user.email'):
            with self.subTest(failed_key=failed_key):
                output = self.run_shell('''
HOME="$TMP/home"; mkdir -p "$HOME/.ssh" "$TMP/bin"
PATH="$TMP/bin:$PATH"; export HOME PATH
FAILED_KEY="''' + failed_key + '''"
git() { [ "$3" != "$FAILED_KEY" ]; }
printf '#!/bin/sh\\necho unexpected-keygen\\nexit 99\\n' > "$TMP/bin/ssh-keygen"
chmod +x "$TMP/bin/ssh-keygen"
if git_ssh_key_setup; then exit 10; else [ "$?" = 1 ]; fi
''', 'Test User\nuser@example.com\n')
                self.assertNotIn('unexpected-keygen', output)

    def test_git_identity_only_prompts_for_missing_fields(self):
        for existing in ('both', 'name', 'email'):
            with self.subTest(existing=existing):
                answer = {'both': '', 'name': 'existing@example.com\n',
                          'email': 'Existing User\n'}[existing]
                output = self.run_shell('''
HOME="$TMP/home"; mkdir -p "$HOME/.ssh"
export HOME GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
''' + ("git config --global user.name 'Existing User'\n" if existing != 'email' else '')
                    + ("git config --global user.email existing@example.com\n" if existing != 'name' else '') + '''
cp "$GIT_CONFIG_GLOBAL" "$TMP/before"
printf original > "$HOME/.ssh/id_ed25519"
git_ssh_key_setup
[ "$(git config --global user.name)" = 'Existing User' ]
[ "$(git config --global user.email)" = existing@example.com ]
[ "$(cat "$HOME/.ssh/id_ed25519")" = original ]
''' + ('cmp "$GIT_CONFIG_GLOBAL" "$TMP/before"\n' if existing == 'both' else ''), answer)
                self.assertEqual('请输入 Git 用户名' in output, existing == 'email')
                self.assertEqual('请输入 Git 邮箱' in output, existing == 'name')

    def test_terminal_tools_and_ssh_keys_are_independent_steps(self):
        self.run_shell('''
apt() { return 1; }
git_ssh_key_setup() { echo unexpected; return 99; }
if terminal_tools_setup; then exit 10; else [ "$?" = 1 ]; fi
apt() { case " $* " in *" git openssh-client "*) return 0 ;; *) return 98 ;; esac; }
terminal_tools_setup
''')

    def test_missing_current_newer_and_unknown(self):
        self.run_shell('''
version_action app '' 2.0
if version_action app 2.0 2.0; then exit 10; else [ "$?" = 1 ]; fi
if version_action app 3.0 2.0; then exit 11; else [ "$?" = 1 ]; fi
if version_action app 1.0 '(none)'; then exit 12; else [ "$?" = 2 ]; fi
if version_action app unknown 2.0; then exit 13; else [ "$?" = 2 ]; fi
''')

    def test_updates_require_answer(self):
        self.run_shell('version_action app 1.0 2.0', 'Y\n')
        self.run_shell('version_action app 1.0 2.0', '\n')
        self.run_shell('if version_action app 1.0 2.0; then exit 10; else [ "$?" = 1 ]; fi')
        self.run_shell('if version_action app 1.0 2.0; then exit 10; else [ "$?" = 1 ]; fi', 'n\n')

    def test_mixed_apt_packages(self):
        output = self.run_shell('''
installed_package_version() {
  case "$1" in current) echo 2.0 ;; older|declined) echo 1.0 ;; esac
}
candidate_package_version() { echo 2.0; }
apt_raw() { printf 'APT_CALL'; printf ' <%s>' "$@"; printf '\\n'; }
apt install -y --no-install-recommends current older declined missing
''', 'y\nn\n')
        call = next(line for line in output.splitlines() if 'APT_CALL' in line)
        self.assertIn('<older>', call)
        self.assertIn('<missing>', call)
        self.assertNotIn('<current>', call)
        self.assertNotIn('<declined>', call)
        self.assertIn('<declined=1.0>', call)
        self.assertIn('<current=2.0>', call)

    def test_all_current_avoids_apt_and_lookup_failure_fails(self):
        self.run_shell('''
installed_package_version() { echo 2.0; }
candidate_package_version() { echo 2.0; }
apt_raw() { exit 99; }
apt install -y current
candidate_package_version() { return 1; }
if apt install -y unknown; then exit 10; else [ "$?" = 1 ]; fi
''')

    def test_git_current_skip_and_fast_forward_update(self):
        self.run_shell('''
git init -q "$TMP/upstream"
git -C "$TMP/upstream" config user.email test@example.com
git -C "$TMP/upstream" config user.name Test
echo first > "$TMP/upstream/file"
git -C "$TMP/upstream" add file
git -C "$TMP/upstream" commit -qm first
git_update "$TMP/local" "$TMP/upstream"
git_update "$TMP/local" "$TMP/upstream"
echo second >> "$TMP/upstream/file"
git -C "$TMP/upstream" commit -qam second
git_update "$TMP/local" "$TMP/upstream"
[ "$(git -C "$TMP/local" rev-parse HEAD)" = "$(git -C "$TMP/upstream" rev-parse HEAD)" ]
''', 'y\n')

    def test_local_deb_version_decision(self):
        output = self.run_shell('''
mkdir -p "$TMP/package/DEBIAN"
printf 'Package: example-app\\nVersion: 2.0\\nArchitecture: all\\nMaintainer: Test <test@example.com>\\nDescription: test\\n' > "$TMP/package/DEBIAN/control"
dpkg-deb --build "$TMP/package" "$TMP/example.deb" >/dev/null
installed_package_version() { echo 1.0; }
apt_raw() { printf 'APT_CALL'; printf ' <%s>' "$@"; printf '\\n'; }
apt install -y "$TMP/example.deb"
''', 'n\n')
        self.assertNotIn('APT_CALL', output)


if __name__ == '__main__':
    unittest.main()
