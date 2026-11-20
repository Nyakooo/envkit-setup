"""Migrate only XDG standard directories using isolated home/config directories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

FUNCTIONS = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split('\n# Single execution entry point.', 1)[0]
NAMES = {'DESKTOP': ('桌面', 'Desktop'), 'DOWNLOAD': ('下载', 'Downloads'),
         'TEMPLATES': ('模板', 'Templates'), 'PUBLICSHARE': ('公共', 'Public'),
         'DOCUMENTS': ('文档', 'Documents'), 'MUSIC': ('音乐', 'Music'),
         'PICTURES': ('图片', 'Pictures'), 'VIDEOS': ('视频', 'Videos')}


class UserDirsTests(unittest.TestCase):
    def setup_dirs(self, home, english=False):
        config = home / '.config'
        config.mkdir()
        lines = []
        for key, names in NAMES.items():
            name = names[1 if english else 0]
            (home / name).mkdir()
            lines.append(f'XDG_{key}_DIR="$HOME/{name}"\n')
        (config / 'user-dirs.dirs').write_text('# Keep this comment\n' + ''.join(lines))
        (config / 'user-dirs.locale').write_text('C\n')
        return config

    def run_setup(self, home):
        return subprocess.run(['sh', '-c', FUNCTIONS + '\ntrap - EXIT\nuser_dirs_setup\n'],
                              env=dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                                       LC_ALL='C.UTF-8', LANG='zh_CN.UTF-8'),
                              capture_output=True, text=True)

    def test_migrates_contents_merges_existing_english_and_updates_bookmarks(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / 'home with spaces'
            home.mkdir()
            config = self.setup_dirs(home)
            (home / 'Documents').mkdir()
            (home / 'Documents/keep.txt').write_text('English content')
            (home / '文档/report.txt').write_text('Chinese directory content')
            (home / '下载/archive').mkdir()
            (home / '下载/archive/test.txt').write_text('download')
            for name in ['go', 'snap', 'workspace', '应用数据']:
                (home / name).mkdir()
                (home / name / 'keep').write_text(name)
            (home / '.pam_environment').write_text('LANG=zh_CN.UTF-8\n')
            bookmarks = config / 'gtk-3.0/bookmarks'
            bookmarks.parent.mkdir()
            bookmarks.write_text((home / '下载').as_uri() + ' 下载\n'
                                 + (home / '文档').as_uri() + '/report.txt My custom label\n')
            result = self.run_setup(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for old, new in NAMES.values():
                self.assertFalse((home / old).exists())
                self.assertTrue((home / new).is_dir())
            self.assertEqual((home / 'Documents/keep.txt').read_text(), 'English content')
            self.assertEqual((home / 'Documents/report.txt').read_text(), 'Chinese directory content')
            self.assertEqual((home / 'Downloads/archive/test.txt').read_text(), 'download')
            self.assertIn((home / 'Downloads').as_uri() + ' Downloads', bookmarks.read_text())
            self.assertIn('/Documents/report.txt My custom label', bookmarks.read_text())
            self.assertIn('# Keep this comment', (config / 'user-dirs.dirs').read_text())
            self.assertEqual((home / '.pam_environment').read_text(), 'LANG=zh_CN.UTF-8\n')
            for name in ['go', 'snap', 'workspace', '应用数据']:
                self.assertEqual((home / name / 'keep').read_text(), name)
            query = subprocess.run(['sh', '-c', '. "$XDG_CONFIG_HOME/user-dirs.dirs"; echo "$XDG_DOWNLOAD_DIR"'], env=dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config)),
                                   capture_output=True, text=True, check=True)
            self.assertEqual(query.stdout.strip(), str(home / 'Downloads'))
            files = [config / 'user-dirs.dirs', config / 'user-dirs.locale', bookmarks, home / 'Documents/report.txt']
            before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in files]
            result = self.run_setup(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('已是英文，跳过', result.stdout)
            self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in files])

    def test_english_configuration_is_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = self.setup_dirs(home, english=True)
            files = [config / 'user-dirs.dirs', config / 'user-dirs.locale']
            before = [path.stat().st_mtime_ns for path in files]
            result = self.run_setup(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(before, [path.stat().st_mtime_ns for path in files])
            self.assertFalse((home / '.local/state/ubuntu-init/desktop-backup/user-dirs').exists())

    def test_conflict_is_detected_before_any_directory_is_moved(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = self.setup_dirs(home)
            (home / 'Documents').mkdir()
            (home / 'Documents/same.txt').write_text('existing')
            (home / '文档/same.txt').write_text('other')
            before = (config / 'user-dirs.dirs').read_bytes()
            result = self.run_setup(home)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('同名冲突', result.stderr)
            self.assertTrue((home / '桌面').exists())
            self.assertFalse((home / 'Desktop').exists())
            self.assertEqual((home / 'Documents/same.txt').read_text(), 'existing')
            self.assertEqual((home / '文档/same.txt').read_text(), 'other')
            self.assertEqual((config / 'user-dirs.dirs').read_bytes(), before)

    def test_custom_disabled_and_symlink_directories_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = self.setup_dirs(home, english=True)
            settings = config / 'user-dirs.dirs'
            text = settings.read_text().replace('$HOME/Downloads', '$HOME/自定义收件箱')
            text = text.replace('$HOME/Desktop', '$HOME/')
            settings.write_text(text)
            (home / '自定义收件箱').mkdir()
            (home / 'Pictures').rmdir()
            (home / 'Pictures').symlink_to(home / 'Documents', target_is_directory=True)
            before = settings.read_bytes()
            result = self.run_setup(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(settings.read_bytes(), before)
            self.assertTrue((home / 'Pictures').is_symlink())
            self.assertTrue((home / '自定义收件箱').is_dir())

    def test_failed_config_commit_restores_original_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = self.setup_dirs(home)
            (home / 'Documents').mkdir()
            (home / '文档/report.txt').write_text('preserve me')
            before = (config / 'user-dirs.dirs').read_bytes()
            code = FUNCTIONS.split('# ubuntu-init standard home directories:', 1)[1].split('\nPYUSERDIRS', 1)[0]
            code = '# standard home directories:' + code
            fault = "from pathlib import Path\ndef fail_replace(self, target):\n    raise OSError('simulated config failure')\nPath.replace = fail_replace\n"
            result = subprocess.run(['python3', '-c', fault + code, str(home / 'state')],
                                    env=dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), LC_ALL='C.UTF-8'),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('simulated config failure', result.stderr)
            self.assertEqual((config / 'user-dirs.dirs').read_bytes(), before)
            self.assertEqual((home / '文档/report.txt').read_text(), 'preserve me')
            self.assertFalse((home / 'Documents/report.txt').exists())
            self.assertTrue((home / '桌面').is_dir())
            self.assertFalse((home / 'Desktop').exists())

    def test_missing_settings_initializes_standard_paths_without_touching_other_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / 'workspace').mkdir()
            result = self.run_setup(home)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for _, english in NAMES.values(): self.assertTrue((home / english).is_dir())
            self.assertTrue((home / 'workspace').is_dir())
            self.assertTrue((home / '.config/user-dirs.dirs').exists())


if __name__ == '__main__':
    unittest.main()
