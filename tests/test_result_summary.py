"""Top-level result accounting across subshell decisions and early failures."""
from pathlib import Path
import subprocess
import tempfile
import unittest

FUNCTIONS = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split('\n# Single execution entry point.', 1)[0]


class ResultSummaryTests(unittest.TestCase):
    def shell(self, code, answer=''):
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(['sh', '-c', FUNCTIONS + '\nTMP="$1"; trap - EXIT\n' + code,
                                   'test', tmp], input=answer, capture_output=True, text=True)

    def test_success_failure_skip_and_declined_update(self):
        result = self.shell('''
results_init
check_version() { if version_action "$@"; then :; else [ "$?" -eq 1 ]; fi; }
optional 'Already current' check_version app 2.0 2.0
optional 'New install' check_version app '' 2.0
optional 'Configuration' true
optional 'Broken component' false
optional 'Declined upgrade' check_version app 1.0 2.0
print_summary
''', 'n\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('成功：2 项  失败：1 项  跳过：2 项', result.stdout)
        self.assertIn('失败项目：Broken component', result.stdout)

    def test_early_failure_still_prints_summary(self):
        result = self.shell('''
results_init
run_step 'Prepared' true
run_step 'Required dependency' false || die 'Cannot continue'
exit 99
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('成功：1 项  失败：1 项  跳过：0 项', result.stdout)
        self.assertIn('Required dependency', result.stdout)

    def test_configuration_counts_success_when_software_skipped(self):
        result = self.shell('''
results_init
configure() {
 if version_action app 2.0 2.0; then :; else [ "$?" -eq 1 ]; fi
 record_step_event change
}
optional 'Config plus current software' configure
print_summary
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('成功：1 项  失败：0 项  跳过：0 项', result.stdout)

    def test_ssh_key_has_its_own_summary_row_and_existing_path(self):
        result = self.shell('''
HOME="$TMP/home"; mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/id_ed25519"
git() { :; }
apt() { record_step_event skip; }
results_init
optional '终端和截图工具' terminal_tools_setup
optional 'Git 配置与 SSH 密钥' git_ssh_key_setup
print_summary
''', 'Test User\nuser@example.com\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('[成功] Git 配置与 SSH 密钥', result.stdout)
        self.assertIn('.ssh/id_ed25519', result.stdout)
        self.assertIn('成功：1 项  失败：0 项  跳过：1 项', result.stdout)

    def test_failure_reason_survives_subshell_and_reaches_summary(self):
        result = self.shell("""
results_init
broken() ( step_failure 'Docker 服务启动失败' '运行 sudo journalctl -u docker -n 50 检查日志'; )
optional Docker broken
print_summary
""")
        self.assertEqual(result.returncode, 1)
        self.assertIn('失败原因：Docker：Docker 服务启动失败', result.stdout)
        self.assertIn('sudo journalctl -u docker -n 50', result.stdout)

    def test_counts_reset_for_next_run(self):
        result = self.shell('''
results_init
optional 'Previous step' true
results_init
print_summary
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('成功：0 项  失败：0 项  跳过：0 项', result.stdout)
