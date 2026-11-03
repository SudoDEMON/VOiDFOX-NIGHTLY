#!/usr/bin/env python3
"""Native macOS recipe. Doctor and dry-run never write to disk."""
import argparse
import fcntl
import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
UPSTREAM = 'https://github.com/mozilla-firefox/firefox.git'
BRANDING = 'browser/branding/voidfox'
PROFILE_PATCH = 'imply_option("MOZ_APP_PROFILE", "VOiDFOX")\n'


def run(*args, cwd=None, env=None, capture=False):
    print('+', shlex.join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def validate_root(value):
    root = Path(value).expanduser().resolve()
    if not Path(value).expanduser().is_absolute():
        raise ValueError('Build root must be an absolute path.')
    if any(c.isspace() for c in str(root)) or any(c in str(root) for c in '\"\'`$\\'):
        raise ValueError('Build root must contain no whitespace or shell metacharacters.')
    if root == Path.home() or len(root.parts) < 3:
        raise ValueError('Choose a dedicated build directory, not a home or filesystem root.')
    if root.parts[1] == 'Volumes':
        volume = Path(*root.parts[:3])
        if len(root.parts) < 4 or not os.path.ismount(volume):
            raise ValueError('External volume must already be mounted; choose a directory beneath it.')
    return root


def choose_python():
    candidates = [os.environ['VOIDFOX_PYTHON']] if os.environ.get('VOIDFOX_PYTHON') else [
        'python3.13', 'python3.14', 'python3.12', 'python3.11', 'python3.10']
    for candidate in candidates:
        executable = shutil.which(candidate)
        if executable:
            result = subprocess.run([executable, '-c',
                'import sys; print("%s.%s" % sys.version_info[:2])'],
                capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip() in {
                    '3.10', '3.11', '3.12', '3.13', '3.14'}:
                return executable
    return None


def mozconfig(root, jobs, pgo):
    lines = [
        f'mk_add_options MOZ_OBJDIR={root}/obj',
        f'mk_add_options MOZ_MAKE_FLAGS="-j{jobs}"',
        'ac_add_options --enable-application=browser',
        f'ac_add_options --with-branding={BRANDING}',
        'ac_add_options --with-distribution-id=net.syntos',
        'ac_add_options --enable-optimize',
        'ac_add_options RUSTC_OPT_LEVEL=2',
        'ac_add_options --disable-debug',
        'ac_add_options --disable-tests',
        'ac_add_options --disable-crashreporter',
        'ac_add_options --disable-updater',
        'ac_add_options --disable-artifact-builds',
        'ac_add_options --disable-debug-symbols',
        'export MOZ_PKG_FORMAT=DMG',
    ]
    if pgo:
        lines += ['ac_add_options MOZ_PGO=1', 'ac_add_options --enable-lto=thin']
    return '\n'.join(lines) + '\n'


def doctor(root):
    issues = []
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        issues.append('Run natively on an Apple Silicon Mac (arm64), outside Rosetta.')
    for command in ('git', 'curl', 'brew', 'xcrun', 'hdiutil', 'codesign',
                    'qlmanage', 'sips', 'iconutil', 'ditto', 'lipo'):
        if not shutil.which(command):
            issues.append(f'Missing tool: {command}')
    python = choose_python()
    if not python:
        issues.append('Install Python 3.13 (brew install python@3.13), or set VOIDFOX_PYTHON.')
    print('Build Python:', python or 'not found')
    if shutil.which('xcodebuild'):
        check = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True)
        if check.returncode:
            issues.append('Full Xcode is not active. Install Xcode and select its developer directory.')
    else:
        issues.append('Full Xcode is required.')
    existing = root
    while not existing.exists():
        existing = existing.parent
    free = shutil.disk_usage(existing).free / 1024**3
    print(f'Build root: {root}\nAvailable: {free:.1f} GiB')
    if free < 80:
        issues.append('Keep at least 80 GiB free for this full-source workflow (recipe safety margin).')
    if not os.access(existing, os.W_OK):
        issues.append(f'Build parent is not writable: {existing}')
    if not (REPO / 'icon.svg').is_file():
        issues.append('Repository icon.svg is missing.')
    for issue in issues:
        print('ERROR:', issue)
    return issues


def prepare_source(root, python, env):
    source = root / 'firefox'
    if not source.exists():
        run('git', 'clone', '--depth=1', '--branch=main', UPSTREAM, source)
    if not (source / '.git').is_dir():
        raise ValueError(f'Refusing to use an unrelated source directory: {source}')
    origin = run('git', 'remote', 'get-url', 'origin', cwd=source, capture=True).strip()
    if origin != UPSTREAM:
        raise ValueError(f'Unexpected Firefox source origin: {origin}')
    restore_profile_config(source)
    branch = run('git', 'branch', '--show-current', cwd=source, capture=True).strip()
    dirty = run('git', 'status', '--porcelain', '--', '.',
                f':(exclude){BRANDING}', cwd=source, capture=True).strip()
    if dirty or branch != 'main':
        raise ValueError('Firefox source has local changes or is not on main; preserve and reconcile them first.')
    run('git', 'fetch', 'origin', 'main', cwd=source)
    # No reset, clean, clobber, or deletion of the source tree.
    run('git', 'merge', '--ff-only', 'FETCH_HEAD', cwd=source)
    run(python, source / 'mach', '--no-interactive', 'bootstrap',
        '--application-choice=browser', '--no-agentic-tools', cwd=source, env=env)
    return source


def restore_profile_config(source):
    """Undo only our exact one-line profile patch before a fast-forward."""
    path = source / 'browser/moz.configure'
    original = run('git', 'show', 'HEAD:browser/moz.configure', cwd=source, capture=True)
    current = path.read_text()
    if current == PROFILE_PATCH + original:
        path.write_text(original)
    elif current != original:
        raise ValueError('browser/moz.configure has user changes; refusing to replace them.')


def prepare_branding(source, root):
    branding = source / BRANDING
    marker = branding / '.voidfox-managed'
    if branding.exists():
        if not marker.is_file() or branding.is_symlink():
            raise ValueError(f'Refusing to overwrite unmanaged branding: {branding}')
        shutil.rmtree(branding)
    shutil.copytree(source / 'browser/branding/unofficial', branding)
    marker.touch()
    (branding / 'configure.sh').write_text(
        'MOZ_APP_DISPLAYNAME=VOiDFOX\nMOZ_MACBUNDLE_ID=voidfox\n')
    config = source / 'browser/moz.configure'
    config.write_text(PROFILE_PATCH + config.read_text())
    # Render the repository SVG with macOS Quick Look, then make a native ICNS.
    with tempfile.TemporaryDirectory(prefix='icon-', dir=root) as scratch:
        scratch = Path(scratch)
        run('qlmanage', '-t', '-s', '1024', '-o', scratch, REPO / 'icon.svg')
        png = scratch / 'icon.svg.png'
        if not png.is_file():
            raise ValueError('Quick Look did not produce the icon thumbnail.')
        iconset = scratch / 'voidfox.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '@2x' if scale == 2 else ''
                run('sips', '-z', str(size * scale), str(size * scale), png,
                    '--out', iconset / f'icon_{size}x{size}{suffix}.png')
        run('iconutil', '-c', 'icns', iconset, '-o', branding / 'firefox.icns')


def install_app(root, source, python, env, package):
    # Mount the packaged app: obj/dist/*.app contains development symlinks.
    with tempfile.TemporaryDirectory(prefix='package-', dir=root) as scratch:
        attached = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse',
                                      '-plist', package, capture=True).encode())
        mounts = [Path(entity['mount-point']) for entity in attached['system-entities']
                  if 'mount-point' in entity]
        try:
            if len(mounts) != 1:
                raise ValueError('Expected one mounted filesystem in the packaged image.')
            apps = list(mounts[0].glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Expected one application in the packaged image.')
            app = Path(scratch) / 'VOiDFOX.app'
            run('ditto', apps[0], app)
        finally:
            for mount in mounts:
                run('hdiutil', 'detach', mount)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'net.syntos.voidfox':
            raise ValueError('Packaged app does not have the expected VOiDFOX bundle identity.')
        resources = app / 'Contents/Resources'
        shutil.copy2(source / BRANDING / 'firefox.icns', resources / 'firefox.icns')
        info['CFBundleIconFile'] = 'firefox.icns'
        info.pop('CFBundleIconName', None)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        ini = (resources / 'application.ini').read_text()
        if 'Profile=VOiDFOX' not in ini:
            raise ValueError('Packaged app does not use the isolated VOiDFOX profile location.')
        distribution = resources / 'distribution'
        distribution.mkdir(exist_ok=True)
        (distribution / 'policies.json').write_text(json.dumps({'policies': {
            'Extensions': {'Install': ['https://addons.mozilla.org/firefox/downloads/latest/icy-void-oled/latest.xpi']}
        }}, indent=2) + '\n')
        run(python, source / 'mach', 'macos-sign', '-c', 'nightly', '-a', app, cwd=source, env=env)
        run('codesign', '--verify', '--deep', '--strict', app)
        architectures = run('lipo', '-archs', app / 'Contents/MacOS/firefox', capture=True)
        if 'arm64' not in architectures.split():
            raise ValueError('Packaged browser is not ARM64.')
        destination = Path.home() / 'Applications/VOiDFOX.app'
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            old = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
            if old.get('CFBundleIdentifier') != 'net.syntos.voidfox':
                raise ValueError('Refusing to replace an application with a different bundle identity.')
            backup = destination.with_name('VOiDFOX-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.app')
            destination.rename(backup)
            try:
                run('ditto', app, destination)
            except Exception:
                if destination.exists():
                    shutil.rmtree(destination)
                backup.rename(destination)
                raise
            print('Previous app retained:', backup)
        else:
            run('ditto', app, destination)
        print('Installed:', destination)
        print('Open with: open ~/Applications/VOiDFOX.app')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--doctor', action='store_true', help='Read-only prerequisites check')
    mode.add_argument('--dry-run', action='store_true', help='Print paths and mozconfig without writing')
    mode.add_argument('--bootstrap-only', action='store_true', help='Prepare toolchain, source, branding and config')
    parser.add_argument('--build-root', default=os.environ.get('VOIDFOX_BUILD_ROOT', '/Volumes/INTEL-2TB/voidfox-macos'))
    parser.add_argument('--jobs', type=int, default=4, help='Compiler jobs (default: 4 for 16 GiB RAM)')
    parser.add_argument('--pgo', action='store_true', help='Enable expensive PGO and ThinLTO')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    root = validate_root(args.build_root)
    config = mozconfig(root, args.jobs, args.pgo)
    if args.dry_run:
        print(f'Source: {root}/firefox\nObjects: {root}/obj\nToolchains: {root}/mozbuild\n'
              f'Install: {Path.home()}/Applications/VOiDFOX.app\n'
              'Profile base: ~/Library/Application Support/VOiDFOX\n\n' + config)
        return 0
    if doctor(root):
        return 1
    if args.doctor:
        print('Doctor passed.')
        return 0
    root.mkdir(parents=True, exist_ok=True)
    with (root / '.build.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another build is already using this build root.')
        return build(root, config, args.bootstrap_only)


def build(root, config, bootstrap_only):
    env = os.environ.copy()
    for key in ('MOZCONFIG', 'MOZ_OBJDIR', 'RUSTFLAGS', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS'):
        env.pop(key, None)
    env['MOZBUILD_STATE_PATH'] = str(root / 'mozbuild')
    env['CARGO_HOME'] = str(root / 'cargo')
    env['RUSTUP_HOME'] = str(root / 'rustup')
    python = choose_python()
    source = prepare_source(root, python, env)
    prepare_branding(source, root)
    config_path = root / 'mozconfig'
    config_path.write_text(config)
    env['MOZCONFIG'] = str(config_path)
    if bootstrap_only:
        print('Prepared source and mozconfig; no compilation performed.')
        return 0
    run(python, source / 'mach', 'build', cwd=source, env=env)
    dist = root / 'obj/dist'
    before = {p: p.stat().st_mtime_ns for p in dist.glob('*.dmg')}
    run(python, source / 'mach', 'package', cwd=source, env=env)
    packages = [p for p in dist.glob('*.dmg') if before.get(p) != p.stat().st_mtime_ns]
    if len(packages) != 1:
        raise ValueError('Packaging did not produce exactly one new or updated DMG.')
    install_app(root, source, python, env, packages[0])
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
