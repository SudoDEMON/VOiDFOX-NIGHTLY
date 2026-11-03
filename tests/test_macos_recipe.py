import contextlib
import importlib.util
import io
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('recipe', Path(__file__).resolve().parents[1] / 'scripts/build_macos.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


class RecipeTests(unittest.TestCase):
    def test_missing_volume_cannot_fall_back_to_internal_disk(self):
        with patch.object(recipe.os.path, 'ismount', return_value=False):
            with self.assertRaisesRegex(ValueError, 'mounted'):
                recipe.validate_root('/Volumes/Disconnected/voidfox')

    def test_whitespace_and_shell_syntax_rejected(self):
        for path in ['/tmp/build with spaces', '/tmp/build$variable', '/tmp/build\nline']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                recipe.validate_root(path)

    def test_symlink_resolves_before_whitespace_check(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'has spaces').mkdir()
            (root / 'alias').symlink_to(root / 'has spaces')
            with self.assertRaises(ValueError):
                recipe.validate_root(root / 'alias')

    def test_home_and_volume_root_rejected(self):
        for path in [Path.home(), '/Volumes/INTEL-2TB', '/']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                recipe.validate_root(path)

    def test_dry_run_does_not_create_build_root_or_run_commands(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'new-build'
            with patch.object(recipe.sys, 'argv', ['recipe', '--dry-run', '--build-root', str(root)]), \
                 patch.object(recipe, 'run', side_effect=AssertionError('mutation')), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(recipe.main(), 0)
            self.assertFalse(root.exists())

    def test_failed_doctor_prevents_bootstrap(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'new-build'
            with patch.object(recipe.sys, 'argv', ['recipe', '--build-root', str(root)]), \
                 patch.object(recipe, 'doctor', return_value=['missing Xcode']), \
                 patch.object(recipe, 'prepare_source') as prepare:
                self.assertEqual(recipe.main(), 1)
                prepare.assert_not_called()
            self.assertFalse(root.exists())

    def test_profile_patch_restored_but_user_edits_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            path = source / 'browser/moz.configure'
            path.parent.mkdir()
            original = '# original\n'
            path.write_text(recipe.PROFILE_PATCH + original)
            with patch.object(recipe, 'run', return_value=original):
                recipe.restore_profile_config(source)
                self.assertEqual(path.read_text(), original)
                path.write_text(recipe.PROFILE_PATCH + original + '# user edit\n')
                edited = path.read_text()
                with self.assertRaises(ValueError):
                    recipe.restore_profile_config(source)
                self.assertEqual(path.read_text(), edited)

    def test_unmanaged_branding_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            branding = root / recipe.BRANDING
            branding.mkdir(parents=True)
            (branding / 'custom.txt').write_text('user data')
            with self.assertRaises(ValueError):
                recipe.prepare_branding(root, root)
            self.assertEqual((branding / 'custom.txt').read_text(), 'user data')

    def check_install(self, fail_signature=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / 'home'
            old = home / 'Applications/VOiDFOX.app'
            (old / 'Contents').mkdir(parents=True)
            identity = {'CFBundleIdentifier': 'net.syntos.voidfox'}
            (old / 'Contents/Info.plist').write_bytes(plistlib.dumps(identity))
            (old / 'old-version').touch()
            source = root / 'firefox'
            (source / recipe.BRANDING).mkdir(parents=True)
            (source / recipe.BRANDING / 'firefox.icns').write_bytes(b'icns')

            def fake_run(*args, **kwargs):
                if args[:2] == ('hdiutil', 'attach'):
                    app = Path(args[-2]) / 'VOiDFOX.app'
                    (app / 'Contents/Resources').mkdir(parents=True)
                    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(identity))
                    (app / 'Contents/Resources/application.ini').write_text('[App]\nProfile=VOiDFOX\n')
                elif args[0] == 'ditto':
                    shutil.copytree(args[1], args[2])
                elif args[0] == 'codesign' and fail_signature:
                    raise subprocess.CalledProcessError(1, args)
                elif args[0] == 'lipo':
                    return 'arm64\n'
                return ''

            with patch.object(recipe.Path, 'home', return_value=home), \
                 patch.object(recipe, 'run', side_effect=fake_run), \
                 contextlib.redirect_stdout(io.StringIO()):
                if fail_signature:
                    with self.assertRaises(subprocess.CalledProcessError):
                        recipe.install_app(root, source, 'python', {}, root / 'package.dmg')
                    self.assertTrue((old / 'old-version').exists())
                    self.assertEqual(list(old.parent.glob('VOiDFOX-*.app')), [])
                else:
                    recipe.install_app(root, source, 'python', {}, root / 'package.dmg')
                    self.assertTrue((old / 'Contents/Resources/distribution/policies.json').exists())
                    backups = list(old.parent.glob('VOiDFOX-*.app'))
                    self.assertEqual(len(backups), 1)
                    self.assertTrue((backups[0] / 'old-version').exists())

    def test_signature_failure_preserves_installed_app(self):
        self.check_install(fail_signature=True)

    def test_install_retains_previous_version(self):
        self.check_install()

    def test_unsupported_python_override_is_rejected(self):
        with patch.dict(os.environ, {'VOIDFOX_PYTHON': 'python3.15'}), \
             patch.object(recipe.shutil, 'which', return_value='/fake/python'), \
             patch.object(recipe.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '3.15\n')):
            self.assertIsNone(recipe.choose_python())


if __name__ == '__main__':
    unittest.main()
