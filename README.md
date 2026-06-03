# VoidFOX

Custom Firefox build from source — "VOiDFOX" (Void Nightly Edition).

This repo holds the build recipe/script used to produce a personalized, optimized Firefox nightly on Linux (KDE Plasma + Wayland).

## The Build Script

The heart of the project is [build.sh](build.sh) — an opinionated, self-contained bash script that:

- Nukes previous build/wrap dirs for clean slate
- Runs Mozilla's bootstrap.py to get Firefox source
- Syncs to latest main
- Writes a tuned `mozconfig` (znver5 / 9950X3D specific, thin LTO, PGO enabled, Wayland GTK, stripped, no debug/tests/crashreporter/updater)
- Builds with `./mach build`
- Installs a custom SVG icon
- Fetches and policy-installs the "icy-void-oled" theme addon
- Creates a small wrapper `~/voidfox/run.sh` that forces Wayland + proper MOZ_APP_REMOTINGNAME for KDE window grouping
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
./build.sh
```

The script is deliberately loud and theatrical. It will refuse to run if safety checks on paths fail.

**Warning**: It does `rm -rf` of the previous build dirs every time. It also modifies your user XDG defaults and mime handlers.

## Configuration Notes (Hard-coded in script)

- `APP_NAME=VOiDFOX`, desktop id `voidfox`
- Profile: `~/.config/mozilla/firefox/drjzrsph.VOID` (can override with `PROFILE_DIR=... ./build.sh`)
- Icon source: `icon.svg` (shipped in this repo, next to build.sh; override with `ICON_SOURCE=...`)
- Installed icon name: `voidfox`
- Build dir: `~/voidfox-build`
- Wrapper/install dir: `~/voidfox`
- CPU opts: znver5 (Zen 5 / 9950X3D), -O3 etc.
- Many Firefox features intentionally disabled for a lean build

## Icon & Assets

The project's SVG icon is now included in the repo as `icon.svg` (imported from the original location). The build script defaults to using the local copy (via `$SCRIPT_DIR/icon.svg`).

If you want to use a different icon, place it as `icon.svg` or override `ICON_SOURCE` when running `./build.sh`. Update this README if the asset location or handling changes.

## History

This started life as a single personal script `~/voidfoxbuild`. It was moved into `~/Projects/VoidFOX/`, renamed internally to `build.sh` for clarity, the project icon was imported, and turned into a git repo (with the standard memory protocol scaffolding) so the recipe itself can be versioned, diffed, and maintained properly.

There is an old GitHub mirror at https://github.com/SudoDEMON/VOiDFOX-NIGHTLY (created very early, before this Projects/ + memory protocol workflow existed). The current local repo is the clean canonical home for the build logic.

## Future Work

- Extract reusable parts / make more portable where sensible
- Add a `doctor` or `--dry-run` mode
- Document exact steps to reproduce the icon asset
- Possibly publish the mozconfig / policy bits separately
- Keep it in sync with upstream Firefox changes that affect custom builds

Run `./build.sh` at your own risk / for your own hardware.
