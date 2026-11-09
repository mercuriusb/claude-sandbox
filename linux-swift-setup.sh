#!/usr/bin/env bash
#
# linux-swift-setup.sh — provision a Swift toolchain so a package's core target can be built/tested
# on Linux (e.g. a CI runner or the dev sandbox). Only UI-free targets and their tests build
# here; UI targets, app extensions and Xcode work stay on macOS.
#
# Why this is not just "swiftly install":
#   - swiftly refuses unknown distros (e.g. Ubuntu 26.04) as "unsupported platform".
#   - The official Swift Linux build targets Ubuntu 24.04; on a newer distro it still runs, but
#     it expects older library SONAMEs than the distro ships: libxml2.so.2 (26.04 has .so.16)
#     and ICU 66. We stage those two as shim libs from Ubuntu 20.04 debs (xz-compressed, so
#     they unpack with python's lzma — no zstd/sudo/apt needed).
#
# Verified: Ubuntu 26.04 LTS aarch64, non-root, Swift 6.3.3. x86_64 paths are wired up but
# untested — adjust SWIFT_VERSION / deb versions if your base differs.
#
# Usage:
#     tools/linux-swift-setup.sh
#     . "$SWIFT_ENV"                       # default: ~/swiftenv.sh
#     cd MyAppCore && swift test
#
# Tunables (env vars):
#     SWIFT_VERSION   Swift release to fetch                 (default 6.3.3)
#     SWIFT_UBUNTU    Ubuntu build to fetch                  (default 24.04)
#     SWIFT_PREFIX    where the toolchain is unpacked        (default ~/swift)
#     SWIFT_LINKLIBS  where shim libs are staged             (default ~/linklibs)
#     SWIFT_ENV       env file the script writes             (default ~/swiftenv.sh)
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
SWIFT_UBUNTU="${SWIFT_UBUNTU:-24.04}"
SWIFT_PREFIX="${SWIFT_PREFIX:-$HOME/swift}"
SWIFT_LINKLIBS="${SWIFT_LINKLIBS:-$HOME/linklibs}"
SWIFT_ENV="${SWIFT_ENV:-$HOME/swiftenv.sh}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- resolve arch-specific bits ------------------------------------------------------------
machine="$(uname -m)"
case "$machine" in
    aarch64|arm64)
        swift_arch_suffix="-aarch64"          # tarball name suffix
        swift_url_arch="-aarch64"             # download dir suffix
        deb_arch="arm64"
        deb_mirror="http://ports.ubuntu.com/ubuntu-ports"
        ;;
    x86_64|amd64)
        swift_arch_suffix=""                  # x86_64 tarballs carry no arch suffix
        swift_url_arch=""
        deb_arch="amd64"
        deb_mirror="http://archive.ubuntu.com/ubuntu"
        ;;
    *)
        echo "Unsupported arch: $machine" >&2; exit 1 ;;
esac

ubuntu_nodot="${SWIFT_UBUNTU//./}"            # 24.04 -> 2404

# --- 1. Swift toolchain --------------------------------------------------------------------
if [ -x "$SWIFT_PREFIX/usr/bin/swift" ]; then
    log "Swift already present at $SWIFT_PREFIX ($("$SWIFT_PREFIX/usr/bin/swift" --version | head -1))"
else
    tarball="swift-${SWIFT_VERSION}-RELEASE-ubuntu${SWIFT_UBUNTU}${swift_arch_suffix}.tar.gz"
    url="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu${ubuntu_nodot}${swift_url_arch}/swift-${SWIFT_VERSION}-RELEASE/${tarball}"
    tmp="$(mktemp -d)"
    log "Downloading $tarball (~1 GB) ..."
    curl -fsSL -o "$tmp/swift.tar.gz" "$url"
    log "Extracting to $SWIFT_PREFIX ..."
    mkdir -p "$SWIFT_PREFIX"
    tar xzf "$tmp/swift.tar.gz" -C "$SWIFT_PREFIX" --strip-components=1
    rm -rf "$tmp"
    log "Installed $("$SWIFT_PREFIX/usr/bin/swift" --version | head -1)"
fi

# --- 2. shim libraries (only what the distro lacks under the expected SONAME) ---------------
mkdir -p "$SWIFT_LINKLIBS"

# stage_deb <deb-url> <space-separated basename prefixes to extract>
stage_deb() {
    local deb_url="$1"; shift
    local tmp; tmp="$(mktemp -d)"
    log "Staging shim libs from $(basename "$deb_url")"
    curl -fsSL -o "$tmp/pkg.deb" "$deb_url"
    ( cd "$tmp" && ar x pkg.deb )
    local data; data="$(ls "$tmp"/data.tar.* )"
    case "$data" in
        *.xz)  DEST="$SWIFT_LINKLIBS" DATA="$data" PREFIXES="$*" python3 - <<'PY'
import lzma, tarfile, io, os, shutil
dest = os.environ["DEST"]; data = os.environ["DATA"]
prefixes = tuple(os.environ["PREFIXES"].split())
with lzma.open(data) as f:
    tf = tarfile.open(fileobj=io.BytesIO(f.read()))
for m in tf.getmembers():
    b = os.path.basename(m.name)
    if m.isfile() and b.startswith(prefixes):
        with tf.extractfile(m) as src, open(os.path.join(dest, b), "wb") as out:
            shutil.copyfileobj(src, out)
        print("  extracted", b)
PY
        ;;
        *) echo "Unexpected data tarball format: $data (need .xz)" >&2; rm -rf "$tmp"; exit 1 ;;
    esac
    rm -rf "$tmp"
}

# Only fetch if the versioned SONAME isn't already staged.
if ! ls "$SWIFT_LINKLIBS"/libxml2.so.2* >/dev/null 2>&1; then
    stage_deb "${deb_mirror}/pool/main/libx/libxml2/libxml2_2.9.10+dfsg-5ubuntu0.20.04.10_${deb_arch}.deb" "libxml2.so.2"
fi
if ! ls "$SWIFT_LINKLIBS"/libicuuc.so.66* >/dev/null 2>&1; then
    stage_deb "${deb_mirror}/pool/main/i/icu/libicu66_66.1-2ubuntu2.1_${deb_arch}.deb" "libicuuc.so libicui18n.so libicudata.so"
fi

# Recreate SONAME symlinks: a real lib like libxml2.so.2.9.10 needs libxml2.so.2
# (SONAME = everything up to and including the first version component after ".so").
( cd "$SWIFT_LINKLIBS"
  for real in *.so.*; do
      [ -f "$real" ] || continue                        # skip existing symlinks
      soname="$(printf '%s' "$real" | sed -E 's/(\.so\.[0-9]+).*/\1/')"
      [ "$soname" = "$real" ] && continue               # already a bare soname
      [ -e "$soname" ] || ln -sf "$real" "$soname"
  done )

# --- 3. env file ---------------------------------------------------------------------------
cat > "$SWIFT_ENV" <<EOF
# Source this to build/test MyAppCore on Linux:
#     . "$SWIFT_ENV" && cd MyAppCore && swift test
export PATH="$SWIFT_PREFIX/usr/bin:\$PATH"
export LD_LIBRARY_PATH="$SWIFT_LINKLIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
log "Wrote env file: $SWIFT_ENV"

log "Done. Next:"
