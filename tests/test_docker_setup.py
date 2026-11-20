"""Docker configuration and anonymous-pull tests, without root, network or a daemon."""
from email.message import Message
from io import BytesIO
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.error import HTTPError

TEXT = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()


def embedded(marker):
    start = TEXT.index(marker)
    return TEXT[start:TEXT.index('\nPY\n', start)]


class Response(BytesIO):
    pass


class DockerTests(unittest.TestCase):
    def probe_namespace(self):
        ns = {'__name__': 'probe_test'}
        exec(embedded('# ubuntu-init Docker mirror probe:'), ns)
        return ns

    def test_anonymous_bearer_pull_checks_digest_and_platform(self):
        ns = self.probe_namespace()
        blob = b'a tiny image layer'
        digest = 'sha256:' + hashlib.sha256(blob).hexdigest()
        manifest = json.dumps({'layers': [{'size': len(blob), 'digest': digest}]}).encode()
        md = 'sha256:' + hashlib.sha256(manifest).hexdigest()
        index = json.dumps({'manifests': [{'digest': md, 'platform': {
            'os': 'linux', 'architecture': 'amd64'}}]}).encode()
        calls = []

        class Opener:
            def open(self, req, timeout):
                calls.append(req)
                if req.full_url.startswith('https://auth.example/'):
                    self_outer.assertNotIn('Authorization', req.headers)
                    return Response(b'{"token":"anonymous-test-token"}')
                if not req.has_header('Authorization'):
                    headers = Message()
                    headers['WWW-Authenticate'] = 'Bearer realm="https://auth.example/token",service="mirror"'
                    raise HTTPError(req.full_url, 401, 'Unauthorized', headers, None)
                if req.full_url.endswith('/latest'): return Response(index)
                if '/manifests/' in req.full_url: return Response(manifest)
                return Response(blob)

        self_outer = self
        ns['build_opener'] = lambda *args: Opener()
        result = ns['probe']('https://mirror.example', 'amd64')
        self.assertEqual(result['bytes'], len(blob))
        self.assertTrue(any('scope=repository%3Alibrary%2Falpine%3Apull' in c.full_url for c in calls))
        wrong_arch = ns['probe']('https://mirror.example', 'arm64')
        self.assertIn('error', wrong_arch)

    def test_html_or_corrupt_images_are_rejected_and_fastest_ranked(self):
        ns = self.probe_namespace()
        class Opener:
            def open(self, req, timeout): return Response(b'<html>login</html>')
        ns['build_opener'] = lambda *args: Opener()
        self.assertIn('error', ns['probe']('https://mirror.example', 'amd64'))
        ranked = ns['rank']([{'url': 'slow', 'bytes_per_second': 1},
                             {'url': 'bad', 'error': 'Forbidden'},
                             {'url': 'fast', 'bytes_per_second': 100}])
        self.assertEqual([r['url'] for r in ranked], ['fast', 'slow'])
        blob = b'bad'
        manifest = json.dumps({'layers': [{'size': 3, 'digest': 'sha256:' + '0'*64}]}).encode()
        class Corrupt:
            def open(self, req, timeout):
                return Response(manifest if '/manifests/' in req.full_url else blob)
        ns['build_opener'] = lambda *args: Corrupt()
        self.assertIn('error', ns['probe']('https://mirror.example', 'amd64'))

    def test_json_merge_preserves_options_and_rejects_invalid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old, mirrors, new = [root / x for x in ('old', 'mirrors', 'new')]
            old.write_text('{"data-root":"/data/docker","log-driver":"local"}')
            mirrors.write_text('{"selected":["https://fast.example","https://fast.example"]}')
            code = embedded('# ubuntu-init Docker daemon merge:')
            cmd = ['/usr/bin/python3', '-c', code, str(old), str(mirrors), str(new)]
            subprocess.run(cmd, check=True)
            self.assertEqual(json.loads(new.read_text()), {
                'data-root': '/data/docker', 'log-driver': 'local',
                'registry-mirrors': ['https://fast.example']})
            first = new.read_text()
            old.write_text('not json')
            self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
            self.assertEqual(first, new.read_text())

    def test_reload_and_rollback_without_restarting_containers(self):
        for active, success, unchanged in [('["https://fast.example/"]', True, False), ('[]', False, False), ('["https://fast.example/"]', True, True), ('[]', False, True)]:
            with self.subTest(success=success), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); etc = root / 'etc'; etc.mkdir()
                original = '{"data-root":"/existing","registry-mirrors":["https://old.example"]}\n'
                if unchanged:
                    original = original.replace('https://old.example', 'https://fast.example')
                (etc / 'daemon.json').write_text(original)
                previous_mtime = (etc / 'daemon.json').stat().st_mtime_ns
                lib = root / 'lib.sh'
                lib.write_text(TEXT[TEXT.index('docker_mirrors() {'):TEXT.index('\ndocker_engine() {')]
                               .replace('/etc/docker', str(etc)))
                command = '''
set -eu
. "$1"
TMP="$2/tmp"; STATE="$2/state"; mkdir -p "$TMP" "$STATE"
sudo() { "$@"; }
say() { :; }
warn() { :; }
record_step_event() { :; }
sleep() { :; }
docker_mirror_probe() { printf '%s' '{"selected":["https://fast.example"]}' > "$TMP/docker-mirrors.json"; }
dockerd() { return 0; }
docker() { printf '%s\\n' "$MOCK_ACTIVE"; }
# Replace systemctl separately to avoid invoking the host service manager.
systemctl() { printf '%s\\n' "$*" >> "$SERVICE_LOG"; }
if docker_mirrors; then exit 0; else exit 1; fi
'''
                result = subprocess.run(['sh', '-c', command, 'test', str(lib), str(root)],
                    env=dict(os.environ, MOCK_ACTIVE=active, SERVICE_LOG=str(root / 'services')),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                if success:
                    self.assertEqual(json.loads((etc / 'daemon.json').read_text())['registry-mirrors'],
                                     ['https://fast.example'])
                else:
                    self.assertEqual((etc / 'daemon.json').read_text(), original)
                if unchanged and success:
                    self.assertEqual((etc / 'daemon.json').stat().st_mtime_ns, previous_mtime)
                    self.assertFalse((root / 'services').exists())
                    continue
                self.assertEqual((etc / 'daemon.json.before-ubuntu-init').read_text(), original)
                services = (root / 'services').read_text()
                self.assertIn('reload docker', services)
                self.assertNotIn('restart', services)

    def test_user_access_refresh_and_failures(self):
        for member, active, fail in [('no', 'no', 'no'), ('yes', 'no', 'no'),
                                     ('yes', 'yes', 'no'), ('no', 'no', 'yes')]:
            with self.subTest(member=member, active=active, fail=fail), tempfile.TemporaryDirectory() as tmp:
                command = TEXT[TEXT.index('docker_user_access() {'):TEXT.index('\n# Keep per-run repository snapshots')]
                command += r"""
say() { :; }; record_step_event() { :; }
id() {
  if [ "$1" = -un ]; then echo tester
  elif [ "$#" = 2 ]; then
    if [ "$MEMBER" = yes ]; then echo 'tester docker'; else echo tester; fi
  else
    if [ "$ACTIVE" = yes ]; then echo 'tester docker'; else echo tester; fi
  fi
}
sudo() {
  printf '%s\n' "$*" >> "$LOG"
  if [ "$1" = -u ]; then
    [ "$2" = tester ] && [ "$3" = -- ] || return 98
    shift 3
    [ "$FAIL" = no ] || return 1
    "$@"
  fi
}
docker() { printf 'docker %s\n' "$*" >> "$LOG"; }
sg() { echo 'sg must not be used' >&2; return 127; }
# No working sg; refresh must run Docker as the same ordinary user.
PATH="$STUB:$PATH"; export PATH
if docker_user_access; then
  printf 'refresh=%s\n' "${DOCKER_GROUP_REFRESH:-no}"
else exit 1; fi
"""
                root = Path(tmp)
                stub = root / 'docker'
                stub.write_text('#!/bin/sh\nprintf "docker %s\\n" "$*" >> "$LOG"\n')
                stub.chmod(0o755)
                result = subprocess.run(['sh', '-c', command], capture_output=True, text=True,
                    env=dict(os.environ, MEMBER=member, ACTIVE=active, FAIL=fail,
                             LOG=str(root / 'log'), STUB=tmp))
                self.assertEqual(result.returncode == 0, fail == 'no', result.stderr)
                log = (root / 'log').read_text()
                self.assertEqual('usermod -aG docker tester' in log, member == 'no')
                self.assertEqual('-u tester -- docker' in log, active == 'no')
                if fail == 'no':
                    self.assertIn('docker version', log)
                    self.assertIn('docker compose version', log)
                    self.assertIn('docker buildx version', log)
                    self.assertIn('refresh=' + ('yes' if active == 'no' else 'no'), result.stdout)

    def test_engine_and_compose_verified_even_when_mirrors_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lib = root / 'engine.sh'
            lib.write_text(TEXT[TEXT.index('step_failure() {'):TEXT.index('\n# Generated candidates')] + TEXT[TEXT.index('docker_engine() {'):TEXT.index('\nswap_setup() {')].replace('/etc/apt', str(root / 'apt')))
            command = '''
set -eu
. "$1"
TMP="$2"; STATE="$2"; ARCH=amd64; CODENAME=resolute
say() { :; }; warn() { :; }; record_step_event() { :; }
apt() { :; }; apt_update() { :; }
candidate_package_version() { echo 1.0; }
dpkg-query() { return 1; }
docker_apt_source() { echo https://mirror.example; }
download() { : > "$2"; }
sudo() {
 printf '%s\\n' "$*" >> "$TMP/commands"
 case "$1" in test) return 1 ;; tee) cat >/dev/null ;; esac
}
docker_mirrors() { return 1; }
docker_user_access() { :; }
docker_engine || exit 99
if docker_mirror_setup; then exit 98; fi
grep -q 'docker version' "$TMP/commands"
grep -q 'docker compose version' "$TMP/commands"
grep -q 'docker buildx version' "$TMP/commands"
'''
            result = subprocess.run(['bash', '-c', command, 'test', str(lib), tmp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
