"""Check official download selection without downloading the large application."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

TEXT = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text()
START = TEXT.index('# ubuntu-init TRAE CN download selection:')
CODE = TEXT[START:TEXT.index('\nPYTRAE', START)]


class TraeCnTests(unittest.TestCase):
    def test_official_architectures_and_rejected_channels(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'release.json'
            base = 'https://lf-cdn.trae.com.cn/obj/trae-com-cn/pkg/app/releases/stable/2.3.1/linux/'
            entry = {'region': 'cn', 'x64.deb': base + 'TRAE_CN-linux-x64.deb',
                     'arm64.deb': base + 'TRAE_CN-linux-arm64.deb'}
            def run(arch):
                path.write_text(json.dumps({'success': True, 'data': {'manifest': {'linux': {'download': [entry]}}}}))
                return subprocess.run(['python3', '-c', CODE, str(path), arch], capture_output=True, text=True)
            for arch, key in [('amd64', 'x64.deb'), ('arm64', 'arm64.deb')]:
                result = run(arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), entry[key])
            entry['x64.deb'] = 'https://untrusted.example/TRAE_CN-linux-x64.deb'
            self.assertNotEqual(run('amd64').returncode, 0)
            entry['region'] = 'sg'
            self.assertNotEqual(run('arm64').returncode, 0)


    def test_missing_install_prompt_precedes_download(self):
        functions = TEXT.split('\n# Single execution entry point.', 1)[0]
        code = functions + '''
installed_package_version() { :; }
download() { echo UNEXPECTED_DOWNLOAD; return 99; }
trae_cn
'''
        result = subprocess.run(['sh', '-c', code], input='n\n', capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('尚未安装 TRAE CN', result.stdout)
        self.assertIn('已跳过', result.stdout)
        self.assertNotIn('UNEXPECTED_DOWNLOAD', result.stdout)
