#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VOiDFOX build script
# Firefox from source, custom launcher, KDE/XDG defaults fixed
# ============================================================

toilet -f wideterm -F border -F metal "FIREFOX - VOiD NIGHTLY EDITION"
toilet -f wideterm -F border -F metal "SACRIFICING 9950X3D TO THE VOiD"

toilet -f wideterm -F border -F metal "PHASE 1: SETTINGS VARIABLES"

# Resolve directory of this script (so relative assets like icon.svg work
# even if the script is run from a different cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="VOiDFOX"
DESKTOP_ID="voidfox"

# Icon now lives in the repo (self-contained). Can be overridden:
#   ICON_SOURCE=... ./build.sh
ICON_SOURCE="${SCRIPT_DIR}/icon.svg"
# Legacy fallback (uncomment if preferred):
# ICON_SOURCE="$HOME/Pictures/VOiD-ICON-GRD.svg"
ICON_NAME="voidfox"

# Profile directory on disk (the 8-char prefix + .VOID is what Firefox chose).
# Override at runtime if needed:
#   PROFILE_DIR=... ./build.sh
PROFILE_DIR="${PROFILE_DIR:-$HOME/.config/mozilla/firefox/drjzrsph.VOID}"

ROOT="$HOME"
BUILD_DIR="$ROOT/voidfox-build"
WRAP_DIR="$ROOT/voidfox"

NUKE_TARGETS=(
  "$BUILD_DIR"
  "$WRAP_DIR"
)

# =========================
# Safety checks
# =========================

[[ "$ROOT" == "$HOME" ]] || {
  echo "ERROR: ROOT must be HOME"
  exit 1
}

[[ -n "${BUILD_DIR:-}" && "$BUILD_DIR" == "$HOME/"* ]] || {
  echo "ERROR: BUILD_DIR looks unsafe: $BUILD_DIR"
  exit 1
}

[[ -n "${WRAP_DIR:-}" && "$WRAP_DIR" == "$HOME/"* ]] || {
  echo "ERROR: WRAP_DIR looks unsafe: $WRAP_DIR"
  exit 1
}

# =========================
# Dependency checks
# =========================

toilet -f wideterm -F border -F metal "PHASE 2: CHECKING RITUAL TOOLS"

for cmd in curl python3 git clang ld.lld jq toilet xdg-mime xdg-settings; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Missing required command: $cmd"
    exit 1
  }
done

# =========================
# Remove old targets
# =========================

toilet -f wideterm -F border -F metal "PHASE 3: NUKING FROM ORBIT"

for p in "${NUKE_TARGETS[@]}"; do
  rm -rf "$p" 2>/dev/null || true
done

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# =========================
# Download bootstrap
# =========================

toilet -f wideterm -F border -F metal "PHASE 4: DOWNLOADING BOOTSTRAP + SOURCE"

curl -fL -o bootstrap.py https://raw.githubusercontent.com/mozilla/firefox/main/python/mozboot/bin/bootstrap.py
python3 bootstrap.py --application-choice=browser --no-interactive

if [[ ! -d "$BUILD_DIR/firefox" ]]; then
  echo "ERROR: $BUILD_DIR/firefox not found. Bootstrap did not clone the source."
  echo "Fix: rerun bootstrap and choose to get Firefox source, or manually clone it into $BUILD_DIR/firefox"
  exit 1
fi

toilet -f wideterm -F border -F metal "FIREFOX SUMMONED"

cat << 'EOF'
              _..--""""--.._
      _   .-""             .----.
     /( .'      _         /.--.. `.
    :  \_..._.-'/         `   .--.\`.
    |.-'       (             `  `. | \
   .'         | `-._            _ |, (
  /       .-   \  |/            `)\)\|.
 / _    .'      \""              ;|  '|
|/'    :   .---. \            ,_|'  . |
'| ,   | .::.(  `-'            )`\  )`|
 |(      ;:.  `.___.---.       | |  | :
 |'      '::          __)    , :    ' :
  ;       `.:.`. __.-'      /|/ /..' :
   \            `._       .' ' / '  /
    \ `\.`.        `-----'   .' '  /
     `.  `\`_             .-'  / .'
       `.       `-----      . '.'
         `-.                .-'
            `--..._____...-'
EOF

# =========================
# Source sync
# =========================

toilet -f wideterm -F border -F metal "PHASE 5: ENTER SOURCE TREE ENSURE LATEST MAIN"

cd "$BUILD_DIR/firefox"
git fetch origin
git reset --hard origin/main

# =========================
# Mozconfig
# =========================

toilet -f wideterm -F border -F metal "PHASE 6: MOZCONFIG FOR 9950X3D + WAYLAND"

cat > mozconfig << 'EOF'
mk_add_options "export RUSTFLAGS=-C target-cpu=znver5 -C codegen-units=1"

ac_add_options --enable-application=browser
ac_add_options --with-branding=browser/branding/unofficial

# Tells mach that PGO is permitted during a "profiled" build invocation
ac_add_options MOZ_PGO=1

ac_add_options --enable-lto=thin
ac_add_options --enable-linker=lld

# Optimized compiler flags for Zen 5 pipeline schedules
ac_add_options --enable-optimize="-O3 -march=znver5 -mtune=znver5 -fno-semantic-interposition"

mk_add_options MOZ_MAKE_FLAGS="-j$(nproc)"

ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --disable-crashreporter
ac_add_options --disable-updater
# Build both GTK backends explicitly: Wayland for the primary KDE session,
# X11 for compatibility paths used by GTK/desktop integration.
ac_add_options --enable-default-toolkit=cairo-gtk3-x11-wayland
ac_add_options --enable-strip

mk_add_options MOZ_DEBUG_SYMBOLS=0
ac_add_options --disable-artifact-builds
EOF

toilet -f wideterm -F border -F metal "MOZCONFIG"
cat mozconfig

# =========================
# Build
# =========================

toilet -f wideterm -F border -F metal "PHASE 7: CLOBBER AND BUILD"

./mach clobber
./mach build

TOP_OBJDIR="$(
  ./mach environment --format json 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["topobjdir"])' \
  || true
)"

[[ -n "$TOP_OBJDIR" ]] || {
  echo "ERROR: TOP_OBJDIR empty. mach environment failed."
  exit 1
}

DISTBIN="$TOP_OBJDIR/dist/bin"

[[ -d "$DISTBIN" ]] || {
  echo "ERROR: Could not find dist/bin at: $DISTBIN"
  exit 1
}

[[ -x "$DISTBIN/firefox" ]] || {
  echo "ERROR: firefox binary not executable at: $DISTBIN/firefox"
  exit 1
}

echo "Top objdir: $TOP_OBJDIR"
grep -E "MOZ_PGO|MOZ_LTO|MOZ_CRASHREPORTER|MOZ_UPDATER" -R "$TOP_OBJDIR/config.status" 2>/dev/null || true

# =========================
# Install icon
# =========================

toilet -f wideterm -F border -F metal "PHASE 8: INSTALL ICON"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "ERROR: Icon not found: $ICON_SOURCE"
  echo "Expected icon path: $ICON_SOURCE"
  exit 1
fi

mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
cp "$ICON_SOURCE" "$HOME/.local/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg"

# =========================
# Install theme policy
# =========================

toilet -f wideterm -F border -F metal "PHASE 9: INSTALLING ICY VOID OLED THEME"

ADDON_SLUG="icy-void-oled"

XPI_URL="$(
  curl -fsSL "https://addons.mozilla.org/api/v5/addons/addon/${ADDON_SLUG}/" \
  | jq -r '.current_version.file.url // empty'
)" || true

if [[ -z "${XPI_URL:-}" ]]; then
  XPI_URL="https://addons.mozilla.org/firefox/downloads/latest/${ADDON_SLUG}/latest.xpi"
fi

echo "Theme XPI URL: ${XPI_URL}"

mkdir -p "$DISTBIN/distribution"

cat > "$DISTBIN/distribution/policies.json" << EOF
{
  "policies": {
    "Extensions": {
      "Install": [
        "${XPI_URL}"
      ]
    }
  }
}
EOF

# =========================
# Create run wrapper
# =========================

toilet -f wideterm -F border -F metal "PHASE 10: CREATE RUN WRAPPER"

mkdir -p "$WRAP_DIR"
rm -f "$WRAP_DIR/run.sh"

cat > "$WRAP_DIR/run.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail

export MOZ_ENABLE_WAYLAND=1

# Must match ${DESKTOP_ID}.desktop and StartupWMClass for KDE grouping.
export MOZ_APP_REMOTINGNAME="${DESKTOP_ID}"

FFBIN="${DISTBIN}/firefox"
PROFILE_DIR="${PROFILE_DIR}"

exec "\$FFBIN" --profile "\$PROFILE_DIR" "\$@"
EOF

chmod 0755 "$WRAP_DIR/run.sh"
cat "$WRAP_DIR/run.sh"

# =========================
# Create desktop entry
# =========================

toilet -f wideterm -F border -F metal "PHASE 11: CREATE KDE DESKTOP ENTRY"

mkdir -p "$HOME/.local/share/applications"

DESKTOP_FILE="$HOME/.local/share/applications/${DESKTOP_ID}.desktop"

rm -f "$DESKTOP_FILE"

cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME}
Comment=Built from source - VOiDFOX
Exec=${WRAP_DIR}/run.sh %u
Icon=${ICON_NAME}
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
StartupWMClass=${DESKTOP_ID}
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/pdf;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;application/x-extension-htm;application/x-extension-html;application/x-extension-shtml;application/x-extension-xht;application/x-extension-xhtml;
EOF

chmod 0644 "$DESKTOP_FILE"
cat "$DESKTOP_FILE"

# =========================
# Set defaults
# =========================

toilet -f wideterm -F border -F metal "PHASE 12: SETTING VOiDFOX DEFAULTS"

rm -f "$HOME/.local/share/applications"/userapp-Nightly-*.desktop

for f in "$HOME/.config/mimeapps.list" "$HOME/.local/share/applications/mimeapps.list"; do
  if [[ -f "$f" ]]; then
    sed -i '/userapp-Nightly-/d' "$f"
  fi
done

xdg-mime default "${DESKTOP_ID}.desktop" x-scheme-handler/http
xdg-mime default "${DESKTOP_ID}.desktop" x-scheme-handler/https
xdg-mime default "${DESKTOP_ID}.desktop" application/pdf

xdg-settings set default-web-browser "${DESKTOP_ID}.desktop" || true

# =========================
# Refresh desktop caches
# =========================

toilet -f wideterm -F border -F metal "PHASE 13: REFRESH KDE CACHES"

gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

if command -v kbuildsycoca6 >/dev/null; then
  kbuildsycoca6
elif command -v kbuildsycoca5 >/dev/null; then
  kbuildsycoca5
elif command -v kbuildsycoca >/dev/null; then
  kbuildsycoca
fi

# =========================
# Verify defaults
# =========================

toilet -f wideterm -F border -F metal "PHASE 14: VERIFY DEFAULTS"

echo "http handler:"
xdg-mime query default x-scheme-handler/http

echo "https handler:"
xdg-mime query default x-scheme-handler/https

echo "pdf handler:"
xdg-mime query default application/pdf

echo "default web browser:"
xdg-settings get default-web-browser || true

echo
toilet -f wideterm -F border -F metal "MISSION COMPLETE"

echo "Run it from KDE app launcher: ${APP_NAME}"
echo "Or from terminal: ${WRAP_DIR}/run.sh"
echo "Desktop file: ${DESKTOP_FILE}"
echo "Icon installed: $HOME/.local/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg"
echo
echo "Important: do not use Firefox/Nightly's internal 'Set as default browser' button yet."
echo "It can regenerate userapp-Nightly-*.desktop and bypass the VOiDFOX wrapper."
