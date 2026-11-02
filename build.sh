#!/bin/sh
# Build a self-contained opencode executable for FreeBSD.
#
# Clones the pinned sources, applies the FreeBSD patches from files/, builds
# every native component (opencode-pty via Ghostty, OpenTUI via Zig, fff via
# Rust), wires up the platform packages that `bun install` skips on FreeBSD,
# and compiles the single-file CLI binary with `bun build --compile`.
#
# Everything lands under work/ and stage/; both are safe to delete to rebuild
# from scratch. Steps are stamped and skipped when already done.
#
# Requirements: git, bun >= 1.4, zig 0.16, cargo (rust), python 3.
#
# Override the build tree with WORK=... (defaults to ./work).

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$ROOT/work}
STAGE=${STAGE:-$ROOT/stage}
CACHE=${CACHE:-$ROOT/distfiles/bun-cache}
STAMPS=$WORK/.stamps

# Pinned sources.
OPENCODE_TAG=v2.2.5
OPENTUI_REV=738067f47e940dcec3f5aab74868908574335c6c # v0.8.0
FFF_REV=459ebcdbdba094843fe5339a1a7f7dae4ced2d82     # v0.10.5
GHOSTTY_REV=ab0b9da9e88fcb4b0533a1854e84628f663930af
OPENTUI_VERSION=0.8.0
FFF_VERSION=0.10.5
OPENCODE_VERSION=${OPENCODE_TAG#v}

case "$(uname -m)" in
  amd64) ARCH=x64 ZIG_ARCH=x86_64 ;;
  aarch64) ARCH=arm64 ZIG_ARCH=aarch64 ;;
  *) echo "error: unsupported machine architecture $(uname -m)" >&2; exit 1 ;;
esac

log() { printf '\n==> %s\n' "$*"; }
have() { [ -f "$STAMPS/$1" ]; }
done_step() { mkdir -p "$STAMPS"; : > "$STAMPS/$1"; }

download() { # download <url> <output>
  if command -v fetch >/dev/null 2>&1; then fetch -o "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then curl -fL -o "$2" "$1"
  elif command -v ftp >/dev/null 2>&1; then ftp -o "$2" "$1"
  else echo "error: no fetch/curl/ftp downloader found" >&2; exit 1
  fi
}

clone_pinned() { # clone_pinned <url> <dir> <rev>
  [ -d "$2/.git" ] && return 0
  log "cloning $1 at $3"
  rm -rf "$2"
  mkdir -p "$2"
  git -C "$2" init -q
  git -C "$2" remote add origin "$1"
  git -C "$2" fetch -q --depth 1 origin "$3"
  git -C "$2" checkout -q FETCH_HEAD
}

apply_patch() { # apply_patch <patch-file> <target-dir> <strip>
  log "patching $(basename "$1")"
  patch -N -p"$3" -d "$2" < "$1"
}

if ! have sources; then
  clone_pinned https://github.com/anomalyco/opencode.git "$WORK/opencode" "$OPENCODE_TAG"
  clone_pinned https://github.com/anomalyco/opentui.git "$WORK/opentui" "$OPENTUI_REV"
  clone_pinned https://github.com/dmtrKovalenko/fff.git "$WORK/fff" "$FFF_REV"
  clone_pinned https://github.com/ghostty-org/ghostty.git "$WORK/ghostty" "$GHOSTTY_REV"
  done_step sources
fi

if ! have patches; then
  apply_patch "$ROOT/files/ghostty-zig-0.16-std.patch" "$WORK/ghostty" 1
  apply_patch "$ROOT/files/opentui-freebsd-targets.patch" "$WORK/opentui" 0
  for p in \
    patch-packages_cli_script_build.ts \
    patch-packages_cli_script_opencode-pty.ts \
    patch-packages_cli_src_heap.ts \
    patch-packages_cli_src_server-process.ts \
    patch-packages_cli_src_services_service-registration.ts
  do
    apply_patch "$ROOT/files/$p" "$WORK/opencode" 0
  done
  done_step patches
fi

# opencode-pty 0.4.0: the daemon binary embedded into the CLI. Its build
# script requires a Ghostty git checkout with HEAD at the pinned revision.
if ! have pty; then
  log "building opencode-pty (cargo release, needs the Ghostty Zig sources)"
  (cd "$WORK/opencode/packages/process-daemon" &&
    env HOME="$WORK" \
      GHOSTTY_SOURCE_DIR="$WORK/ghostty" \
      OPENCODE_ZIG_CPU=baseline \
      ZIG_GLOBAL_CACHE_DIR="$WORK/zig-pty-cache" \
      cargo build --release --locked)
  done_step pty
fi

# OpenTUI: the TUI renderer shared library (libopentui.so).
if ! have opentui; then
  log "building OpenTUI native renderer (zig ReleaseFast)"
  (cd "$WORK/opentui/packages/native" &&
    env HOME="$WORK" \
      ZIG_GLOBAL_CACHE_DIR="$WORK/zig-cache" \
      ZIG_LOCAL_CACHE_DIR="$WORK/zig-cache-local" \
      sh scripts/prepare-zig-deps.sh &&
    env HOME="$WORK" \
      ZIG_GLOBAL_CACHE_DIR="$WORK/zig-cache" \
      ZIG_LOCAL_CACHE_DIR="$WORK/zig-cache-local" \
      zig build -Doptimize=ReleaseFast)
  LIBOPENTUI="$WORK/opentui/packages/native/lib/$ZIG_ARCH-freebsd/libopentui.so"
  [ -f "$LIBOPENTUI" ] || { echo "error: $LIBOPENTUI not built" >&2; exit 1; }
  done_step opentui
fi

# fff: the fuzzy file finder shared library (libfff_c.so).
if ! have fff; then
  log "building fff native library (cargo release)"
  (cd "$WORK/fff" && cargo build --release --locked -p fff-c)
  [ -f "$WORK/fff/target/release/libfff_c.so" ] || { echo "error: libfff_c.so not built" >&2; exit 1; }
  done_step fff
fi

# opencode dependencies. bun install skips packages whose npm metadata
# excludes FreeBSD, so @ff-labs/fff-bun must be unpacked and patched by hand
# (afterwards never run bun install again, it would prune the manual edits).
if ! have node_modules; then
  log "installing opencode dependencies (bun)"
  (cd "$WORK/opencode" &&
    env HOME="$WORK" BUN_INSTALL_CACHE_DIR="$CACHE" bun install)

  log "installing @ff-labs/fff-bun from the npm tarball"
  mkdir -p "$WORK/opencode/node_modules/@ff-labs"
  download "https://registry.npmjs.org/@ff-labs/fff-bun/-/fff-bun-$FFF_VERSION.tgz" "$WORK/fff-bun.tgz"
  rm -rf "$WORK/opencode/node_modules/@ff-labs/fff-bun" "$WORK/fff-bun-pkg"
  mkdir -p "$WORK/fff-bun-pkg"
  tar -xzf "$WORK/fff-bun.tgz" -C "$WORK/fff-bun-pkg"
  mv "$WORK/fff-bun-pkg/package" "$WORK/opencode/node_modules/@ff-labs/fff-bun"
  (cd "$WORK/opencode" &&
    patch -N -p1 -d node_modules/@ff-labs/fff-bun \
      < "patches/@ff-labs%2Ffff-bun@$FFF_VERSION.patch")

  log "creating FreeBSD platform packages and patching the JS bundles"
  LIBOPENTUI="$WORK/opentui/packages/native/lib/$ZIG_ARCH-freebsd/libopentui.so"
  python3 "$ROOT/files/setup-opentui-freebsd.py" "$WORK/opencode" "$LIBOPENTUI" "$OPENTUI_VERSION" "$ARCH"
  python3 "$ROOT/files/setup-fff-freebsd.py" "$WORK/opencode" "$WORK/fff/target/release/libfff_c.so" "$FFF_VERSION" "$ARCH"
  done_step node_modules
fi

# The CLI: one ~227 MB executable embedding the web UI, TUI renderer, fff and
# the PTY daemon.
if ! have cli; then
  log "compiling the opencode CLI (freebsd-$ARCH)"
  (cd "$WORK/opencode/packages/cli" &&
    env HOME="$WORK" \
      BUN_INSTALL_CACHE_DIR="$CACHE" \
      OPENCODE_VERSION="$OPENCODE_VERSION" \
      OPENCODE_TARGET="freebsd-$ARCH" \
      OPENCODE_PTY_BIN="$WORK/opencode/packages/process-daemon/target/release/opencode-pty" \
      bun run script/build.ts --skip-install --outdir=dist)
  BIN="$WORK/opencode/packages/cli/dist/cli-freebsd-$ARCH/bin/opencode"
  [ -f "$BIN" ] || { echo "error: CLI binary not built" >&2; exit 1; }
  done_step cli
fi

log "staging the binary"
mkdir -p "$STAGE"
cp "$WORK/opencode/packages/cli/dist/cli-freebsd-$ARCH/bin/opencode" "$STAGE/opencode"
chmod +x "$STAGE/opencode"
echo "done: $STAGE/opencode ($(uname -s) $ARCH, opencode $OPENCODE_VERSION)"

# opencode's ripgrep bootstrap has no FreeBSD download and only falls back to
# a system rg; it backs the grep/glob tools and non-VCS file search.
if ! command -v rg >/dev/null 2>&1; then
  echo "note: system ripgrep not found — 'pkg install ripgrep' is needed at runtime" >&2
fi
