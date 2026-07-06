# VoidFOX

Custom Firefox build from source — "VOiDFOX" (Void Nightly Edition).

This repo holds the build recipe/script used to produce a personalized, optimized Firefox nightly on Linux (KDE Plasma + Wayland).

## The Build Script

The heart of the project is [build.sh](build.sh) — an opinionated, self-contained bash script that:

- Nukes previous build/wrap dirs for clean slate
- Runs Mozilla's bootstrap.py to get Firefox source
- Syncs to latest main
- Writes a tuned `mozconfig` (znver5 / 9950X3D specific, thin LTO, PGO enabled, explicit GTK X11+Wayland backends, stripped, no debug/tests/crashreporter/updater)
- Builds with `./mach build`
- Installs a custom SVG icon
- Fetches and policy-installs the "icy-void-oled" theme addon
- Creates a small wrapper `~/voidfox/run.sh` that defaults to Wayland + proper MOZ_APP_REMOTINGNAME for KDE window grouping, plus X11/safe-mode/graphics-log diagnostic wrappers
- Creates a `.desktop` entry, sets it as default browser for http/https/pdf via xdg
- Refreshes all the KDE/icon/mime caches (including kbuildsycoca*)

After a successful run you launch via the app menu ("VOiDFOX") or `~/voidfox/run.sh`.

## Prerequisites

- `toilet` (for the fancy phase banners — optional but expected by the script)
- Standard build deps (script checks for: curl, python3, git, clang, ld.lld, jq, xdg-mime, xdg-settings)
- The Firefox bootstrap will pull the rest (rust, etc.)
- Plenty of RAM, disk space, and time (full optimized build from source)

## Usage

```bash
cd ~/Projects/VoidFOX
./build.sh --doctor
./build.sh --help
./build.sh --reset-risky-prefs
./build.sh
```

The script is deliberately loud and theatrical. It will refuse to run if safety checks on paths fail.

**Warning**: It does `rm -rf` of the previous build dirs every time. It also modifies your user XDG defaults and mime handlers.

`./build.sh --doctor` is non-destructive. Use it first when diagnosing the current local build/profile.

## Runtime Diagnostics

For stale rendered surfaces on NVIDIA/KDE Wayland, start with profile/runtime tests before changing compiler flags or doing another full build. Close all VOiDFOX windows before these tests so Firefox does not remote the request into the already-running instance.

```bash
cd ~/Projects/VoidFOX
./build.sh --doctor
./build.sh --reset-risky-prefs
~/voidfox/run-safe-mode.sh
~/voidfox/run-x11.sh
~/voidfox/run-gfx-log.sh
```

`--reset-risky-prefs` backs up `prefs.js` into `~/voidfox-diagnostics/` and removes only the risky graphics/video force-enable lines listed below. It refuses to run while VOiDFOX is open.

`run-safe-mode.sh` starts Firefox safe mode with the normal VOiDFOX profile. If the issue disappears there, suspect profile prefs, extensions, theme, or forced graphics settings.

`run-x11.sh` starts the same build/profile with `MOZ_ENABLE_WAYLAND=0`. If the issue disappears there but not in safe mode, suspect the NVIDIA/KDE Wayland path.

`run-gfx-log.sh` writes graphics-related logs to `~/voidfox-diagnostics/voidfox-gfx.log` by default. Override with `VOIDFOX_DIAG_DIR=...` or `MOZ_LOG_FILE=...` if needed.

The profile should not force graphics/video acceleration prefs unless there is a specific reason. In particular, reset these before treating the build as broken:

```text
layers.acceleration.force-enabled
media.hardware-video-decoding.force-enabled
media.hardware-video-encoding.force-enabled
media.navigator.mediadatadecoder_vp8_hardware_enabled
```

## Configuration Notes (Hard-coded in script)

- `APP_NAME=VOiDFOX`, desktop id `voidfox`
- Profile: `~/.config/mozilla/firefox/drjzrsph.VOID` (can override with `PROFILE_DIR=... ./build.sh`)
- Icon source: `icon.svg` (shipped in this repo, next to build.sh; override with `ICON_SOURCE=...`)
- Installed icon name: `voidfox`
- Build dir: `~/voidfox-build`
- Wrapper/install dir: `~/voidfox`
- Runtime diagnostics/log scratch dir: `~/voidfox-diagnostics` (can override with `VOIDFOX_DIAG_DIR=...`)
- CPU opts: znver5 (Zen 5 / 9950X3D), -O3 etc.
- Many Firefox features intentionally disabled for a lean build

## Icon & Assets

The project's SVG icon is now included in the repo as `icon.svg` (imported from the original location). The build script defaults to using the local copy (via `$SCRIPT_DIR/icon.svg`).

If you want to use a different icon, place it as `icon.svg` or override `ICON_SOURCE` when running `./build.sh`. Update this README if the asset location or handling changes.

## History

This started life as a single personal script `~/voidfoxbuild`. It was moved into `~/Projects/VoidFOX/`, renamed internally to `build.sh` for clarity, the project icon was imported, and turned into a git repo (with the standard memory protocol scaffolding) so the recipe itself can be versioned, diffed, and maintained properly.

The GitHub remote (origin) is https://github.com/SudoDEMON/VOiDFOX-NIGHTLY (SSH: git@github.com:SudoDEMON/VOiDFOX-NIGHTLY.git). The current local tree (clean bootstrap with proper layout, icon.svg, docs, and renamed script) is the canonical version. User pushed the clean history 2026-06-03 (`git push -u origin main --force-with-lease`); it is now live as the published canonical state (early 2026-03 single-file "voidfoxbuild" commit superseded).

## Future Work

- Add `DRY_RUN=1` (or `--dry-run`) support so generated files and path decisions can be validated without a full multi-hour build
- Harden TOP_OBJDIR extraction and add more upfront soft checks (disk space, additional tools like gtk-update-icon-cache)
- Write build provenance info (recipe git hash, date, key flags) into the wrapper dir after each successful run
- Improve profile ergonomics (better docs + perhaps a helper to discover the on-disk dir name)
- Clarify PGO behavior in comments/docs (MOZ_PGO=1 + `./mach build` triggers automated instrument+train+optimize)
- Extract reusable parts / make more portable where sensible (without breaking the "single ./build.sh" contract)
- Possibly publish the mozconfig / policy bits separately
- Keep it in sync with upstream Firefox changes that affect custom builds (bootstrap.py, mach environment format, etc.)

Run `./build.sh` at your own risk / for your own hardware.
