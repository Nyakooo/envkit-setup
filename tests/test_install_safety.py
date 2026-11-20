"""Exercise failure/retry paths with real shell functions and isolated system files."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


FUNCTIONS = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split(
    '\n# Single execution entry point.', 1)[0]


class InstallSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ubuntu-safety-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('home', 'tmp', 'state', 'bin', 'apt/sources.list.d', 'apt/keyrings'):
            (self.root / name).mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.root / 'home'), ROOT=str(self.root),
                        PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])
        self.env.pop('ZDOTDIR', None)
        self.source = FUNCTIONS.replace('/etc/apt', str(self.root / 'apt'))

    def shell(self, body, answer=''):
        code = self.source + '''
trap - EXIT
TMP="$ROOT/tmp"; STATE="$ROOT/state"; ARCH=amd64; CODENAME=noble
sudo() { "$@"; }
''' + body
        result = subprocess.run(['sh', '-c', code], env=self.env, input=answer,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def executable(self, name, code):
        path = self.root / 'bin' / name
        path.write_text('#!/bin/sh\nset -eu\n' + code)
        path.chmod(0o755)

    def test_architecture_sources_and_official_fallback(self):
        for arch, available, path in [('amd64', 'yes', 'ubuntu'), ('arm64', 'yes', 'ubuntu-ports'),
                                      ('amd64', 'no', 'ubuntu'), ('arm64', 'no', 'ubuntu-ports')]:
            with self.subTest(arch=arch, available=available):
                self.shell(f'''
ARCH={arch}; AVAILABLE={available}
mirror_probe() {{ printf '%s\\n' "$1" >> "$TMP/probes"; [ "$AVAILABLE" = yes ]; }}
set_mirror
''')
                source = (self.root / 'apt/sources.list.d/ubuntu.sources').read_text()
                if available == 'yes':
                    self.assertIn('URIs: https://mirrors.', source)
                elif arch == 'arm64':
                    self.assertIn('URIs: https://ports.ubuntu.com/ubuntu-ports', source)
                    self.assertNotIn('archive.ubuntu.com', source)
                    self.assertNotIn('security.ubuntu.com', source)
                else:
                    self.assertIn('URIs: https://archive.ubuntu.com/ubuntu', source)
                    self.assertIn('URIs: https://security.ubuntu.com/ubuntu', source)
                self.assertIn('/' + path + '\n', source)
                self.assertIn('noble-security', source)

    def test_mirror_probe_checks_all_pockets_for_target_architecture(self):
        self.shell('''
ARCH=arm64
curl() { printf '%s\\n' "$*" >> "$TMP/requests"; case "$*" in *noble-security*) return 1 ;; esac; }
if mirror_probe https://mirror.example/ubuntu-ports; then exit 99; fi
''')
        requests = (self.root / 'tmp/requests').read_text().splitlines()
        self.assertEqual(len(requests), 3)
        for pocket in ('noble', 'noble-updates', 'noble-security'):
            self.assertTrue(any(f'/dists/{pocket}/main/binary-arm64/Packages.xz' in x for x in requests))

    def test_verified_proxy_survives_user_zsh_config_without_changing_it(self):
        zrc = self.root / 'home/.zshrc'
        original = '''export PATH="$HOME/node bin:$PATH"
export NVM_DIR="$HOME/nvm"
export http_proxy=http://127.0.0.1:9999
export https_proxy=$http_proxy HTTP_PROXY=$http_proxy HTTPS_PROXY=$http_proxy
export all_proxy=$http_proxy ALL_PROXY=$http_proxy no_proxy='*' NO_PROXY='*'
'''
        zrc.write_text(original)
        self.shell('''
export PROXY_PORT=18080
export_proxy_env
refresh_zsh_env
for proxy in "$http_proxy" "$https_proxy" "$HTTP_PROXY" "$HTTPS_PROXY" "$all_proxy" "$ALL_PROXY"; do
  [ "$proxy" = http://127.0.0.1:18080 ]
done
[ "$no_proxy" = localhost,127.0.0.1,::1 ] && [ "$NO_PROXY" = "$no_proxy" ]
[ "$NVM_DIR" = "$HOME/nvm" ]
case "$PATH" in "$HOME/node bin:"*) ;; *) exit 98 ;; esac
''')
        self.assertEqual(zrc.read_text(), original)

    def docker_stubs(self):
        return '''
download() { [ ! -f "$ROOT/fail-key" ] || return 1; printf 'new-key' > "$2"; }
docker_apt_source() { printf '%s\\n' https://mirror.example https://fallback.example; }
apt_update() { [ ! -f "$ROOT/fail-index" ]; }
candidate_package_version() { echo 2.0; }
installed_package_version() {
  if [ -f "$ROOT/ce-current" ]; then cat "$ROOT/ce-current"; fi
}
apt_raw() {
  printf '%s\\n' "$*" >> "$ROOT/apt-commands"
  case " $* " in
    *' --download-only '*) [ ! -f "$ROOT/fail-download" ] || return 1 ;;
    *) [ ! -f "$ROOT/fail-install" ] || return 1; touch "$ROOT/replaced" ;;
  esac
}
'''

    def test_docker_preparation_failures_preserve_installed_packages_and_sources(self):
        paths = [self.root / 'apt' / name for name in
                 ('sources.list.d/docker.list', 'sources.list.d/docker.sources', 'keyrings/docker.asc')]
        for path in paths:
            path.write_text('original ' + path.name)
            path.chmod(0o640)
        originals = [(p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns) for p in paths]
        for failure in ('key', 'index', 'download', 'install'):
            with self.subTest(failure=failure):
                flag = self.root / ('fail-' + failure)
                flag.touch()
                self.shell(self.docker_stubs() + 'if docker_packages "docker.io containerd runc"; then exit 99; fi\n')
                flag.unlink()
                self.assertEqual(originals, [(p.read_bytes(), p.stat().st_mode, p.stat().st_mtime_ns) for p in paths])
                self.assertFalse((self.root / 'replaced').exists())
                calls = self.root / 'apt-commands'
                if calls.exists():
                    self.assertNotIn('remove -y', calls.read_text())

    def test_docker_success_prefetches_same_replacement_plan_and_can_rerun(self):
        self.shell(self.docker_stubs() + 'docker_packages "docker.io containerd runc"\n')
        calls = (self.root / 'apt-commands').read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].replace(' --download-only', ''), calls[1])
        self.assertIn('docker.io- containerd- runc-', calls[1])
        self.assertTrue((self.root / 'replaced').exists())
        self.assertIn('https://mirror.example', (self.root / 'apt/sources.list.d/docker.list').read_text())
        (self.root / 'ce-current').write_text('2.0')
        self.shell(self.docker_stubs() + 'docker_packages ""\n')
        self.assertEqual((self.root / 'apt-commands').read_text().splitlines(), calls)

    def test_docker_failed_fresh_setup_removes_new_source_files(self):
        (self.root / 'fail-download').touch()
        self.shell(self.docker_stubs() + 'if docker_packages "docker.io"; then exit 99; fi\n')
        self.assertFalse((self.root / 'apt/sources.list.d/docker.list').exists())
        self.assertFalse((self.root / 'apt/keyrings/docker.asc').exists())
        self.assertFalse((self.root / 'replaced').exists())

    def test_docker_declined_updates_do_not_download_or_replace(self):
        (self.root / 'ce-current').write_text('1.0')
        self.shell(self.docker_stubs() + 'docker_packages ""\n', 'n\n' * 5)
        self.assertFalse((self.root / 'apt-commands').exists())
        self.assertFalse((self.root / 'replaced').exists())

    def prepare_swap(self):
        self.source = re.sub(r'/swapfile(?![\w-])', str(self.root / 'swapfile'), self.source)
        self.source = self.source.replace('/etc/fstab', str(self.root / 'fstab'))
        self.source = self.source.replace('/proc/meminfo', str(self.root / 'meminfo'))
        (self.root / 'fstab').write_text('# existing mounts\n')
        (self.root / 'active').write_text('')
        (self.root / 'meminfo').write_text('MemTotal: 4194304 kB\n')
        self.executable('fallocate', '''
[ "$(stat -c %a "$3")" = 600 ]
[ ! -f "$ROOT/fail-allocation" ] || exit 1
printf allocated > "$3"
''')
        self.executable('mkswap', '''
[ ! -f "$ROOT/fail-format" ] || exit 1
printf valid > "$1"
''')
        return '''
sudo() {
  case "$1" in tee) [ ! -f "$ROOT/fail-fstab" ] || return 1 ;; esac
  "$@"
}
findmnt() { printf ext4; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nroot 99999999 0 99999999 0%% /\\n'; }
swapon() {
  if [ "$1" = --show ]; then cat "$ROOT/active"; return; fi
  [ "$(cat "$1")" = valid ] || return 1
  printf '%s\\n' "$1" > "$ROOT/active"
}
'''

    def test_swap_new_file_failure_cleanup_then_success_and_rerun(self):
        stubs = self.prepare_swap()
        for failure in ('allocation', 'format'):
            with self.subTest(failure=failure):
                flag = self.root / ('fail-' + failure)
                flag.touch()
                self.shell(stubs + 'if swap_setup; then exit 99; fi\n')
                flag.unlink()
                self.assertFalse((self.root / 'swapfile').exists())
        self.shell(stubs + 'swap_setup\n')
        swap = self.root / 'swapfile'
        before = (swap.read_bytes(), swap.stat().st_mtime_ns)
        fstab = (self.root / 'fstab').read_bytes()
        self.shell(stubs + 'swap_setup\n')
        self.assertEqual(before, (swap.read_bytes(), swap.stat().st_mtime_ns))
        self.assertEqual(fstab, (self.root / 'fstab').read_bytes())

    def test_swap_active_managed_file_repairs_failed_fstab_write(self):
        stubs = self.prepare_swap()
        flag = self.root / 'fail-fstab'
        flag.touch()
        self.shell(stubs + 'if swap_setup; then exit 99; fi\n')
        self.assertTrue((self.root / 'state/swapfile-managed').exists())
        self.assertTrue((self.root / 'active').read_text())
        flag.unlink()
        self.shell(stubs + 'swap_setup\nswap_setup\n')
        self.assertEqual((self.root / 'fstab').read_text().count(' none swap sw 0 0'), 1)

    def test_swap_interrupted_format_removes_only_the_new_file(self):
        stubs = self.prepare_swap()
        self.executable('mkswap', 'kill -TERM "$PPID"\nexit 130\n')
        self.shell(stubs + 'if swap_setup; then exit 99; fi\n')
        self.assertFalse((self.root / 'swapfile').exists())
        self.assertEqual((self.root / 'active').read_text(), '')

    def test_swap_creation_race_does_not_truncate_or_remove_existing_file(self):
        stubs = self.prepare_swap()
        self.shell(stubs + '''
sudo() {
  if [ "$1" = sh ]; then printf 'appeared concurrently' > "$ROOT/swapfile"; fi
  "$@"
}
if swap_setup; then exit 99; fi
''')
        self.assertEqual((self.root / 'swapfile').read_text(), 'appeared concurrently')

    def test_swap_existing_invalid_file_and_unmanaged_active_swap_are_preserved(self):
        stubs = self.prepare_swap()
        swap = self.root / 'swapfile'
        swap.write_text('user file')
        self.shell(stubs + 'if swap_setup; then exit 99; fi\n')
        self.assertEqual(swap.read_text(), 'user file')
        (self.root / 'active').write_text('/dev/user-swap\n')
        self.shell(stubs + 'swap_setup\n')
        self.assertEqual((self.root / 'fstab').read_text(), '# existing mounts\n')


if __name__ == '__main__':
    unittest.main()
