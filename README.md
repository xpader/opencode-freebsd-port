# opencode on FreeBSD

Build scripts and patches to produce a **self-contained [opencode](https://github.com/anomalyco/opencode)
executable for FreeBSD**, built from the upstream sources of a given release.
The result is a single ~230 MB binary with the web UI, the OpenTUI terminal
renderer, the fff fuzzy file finder and the PTY daemon all embedded — the same
artifact shape as the official Linux/macOS builds.

The FreeBSD ports tree carries opencode (misc/opencode) but lags behind
upstream, and opencode itself publishes no FreeBSD binaries. This repo is the
gap filler: it builds any pinned release on a FreeBSD machine with the tools
listed below, and its `files/` are kept in FreeBSD port style so they can be
fed back into the port.

Current pins: **opencode v2.2.5**, OpenTUI 0.8.0, fff 0.10.5,
@opencode/pty 0.4.0, Ghostty `ab0b9da9e88f`.

## Quick start

```sh
sh build.sh
./stage/opencode --version
```

Requirements:

| tool | version | notes |
|------|---------|-------|
| FreeBSD | 14+ | tested on 15.1-RELEASE amd64 |
| git | any | |
| bun | >= 1.4.4 | the official upstream binary works; `bun:ffi` is functional |
| zig | 0.16.0 | `pkg install zig` |
| rust + cargo | any recent | for opencode-pty and fff |
| python3 | 3.x | for the setup scripts |

Disk: ~6 GB free for `work/` and caches. First build takes a while (Ghostty +
Rust + Zig release builds); subsequent steps are stamped and skipped. Delete
`work/` to force a rebuild.

Install the binary wherever you like, e.g. `cp stage/opencode ~/.local/bin/`.

## What the build does

1. Shallow-clones the four pinned sources (opencode, opentui, fff, ghostty).
2. Applies the patches from `files/` (see below).
3. Builds `opencode-pty` with cargo against the Ghostty sources
   (`GHOSTTY_SOURCE_DIR`; the build script verifies the checkout revision).
4. Builds OpenTUI's `libopentui.so` with Zig.
5. Builds fff's `libfff_c.so` with cargo.
6. `bun install` in the opencode tree, then:
   - unpacks `@ff-labs/fff-bun` from the npm tarball by hand (its npm
     metadata claims `os: ["!freebsd"]`, so bun skips it) and applies
     opencode's own ESM patch to it;
   - runs `setup-opentui-freebsd.py` / `setup-fff-freebsd.py`, which create
     the `@opentui/core-freebsd-x64` and `@ff-labs/fff-bin-freebsd-x64`
     platform packages around the built `.so` files and patch the bundled
     JS loaders to resolve them;
   - after this point `bun install` must never run again — it would prune
     the manual additions.
7. Compiles the CLI with `bun run script/build.ts --skip-install` into a
   single executable (`bun build --compile`) and copies it to `stage/`.

## The patches in `files/`

| file | purpose |
|------|---------|
| `patch-packages_cli_script_build.ts` | teach the CLI build script the freebsd targets (no @parcel/watcher package exists; bun emits no bytecode there) |
| `patch-packages_cli_script_opencode-pty.ts` | accept freebsd in the PTY-embed whitelist |
| `patch-packages_cli_src_heap.ts` | **bug fix:** skip the SIGUSR1 heap handler on FreeBSD (see below) |
| `patch-packages_cli_src_server-process.ts` | **bug fix:** normalize wildcard addresses in the service probe URL |
| `patch-packages_cli_src_services_service-registration.ts` | **bug fix:** advertise a connectable URL in `service.json` for wildcard binds |
| `opentui-freebsd-targets.patch` | freebsd targets in OpenTUI's `build.zig` + enable the Ghostty VT backend |
| `ghostty-zig-0.16-std.patch` | rename `trimRight/trimLeft` -> `trimEnd/trimStart` for Zig 0.16 |
| `setup-opentui-freebsd.py`, `setup-fff-freebsd.py` | create the platform packages and patch the bundled JS |
| `webui-wasm-package.json` | WASM fallback deps for the web UI's native bindings (arm64 only, see below) |

### The two runtime bugs

**SIGUSR1 deadlock (`heap.ts`).** opencode registers `process.on("SIGUSR1")`
to expose on-demand heap snapshots. On FreeBSD, Bun's JavaScriptCore uses
SIGUSR1 internally for stop-the-world GC thread suspension; taking the signal
over makes the next GC deadlock the whole process (ktrace shows it hanging
right after signaling itself, unresponsive even to SIGTERM). This is really a
Bun problem — the `lang/bun` port patches Bun itself for the same reason — but
skipping the handler in opencode is a cheap, defensive fix.

**Wildcard service URL (`service-registration.ts`, `server-process.ts`).** With
`hostname: "0.0.0.0"` configured, opencode wrote `http://0.0.0.0:<port>` into
`~/.local/state/opencode/service.json`. Linux connects to 0.0.0.0 as if it
were loopback (historical quirk), FreeBSD returns ENETUNREACH — so
`opencode service status` reported a running server as stopped and
`service start` timed out. The fixes normalize wildcard addresses to loopback
in the advertised/probed URLs only; the bind stays wildcard.

Both are worth reporting upstream (the second also affects macOS); patches are
in port format and can be attached as-is.

## Layout

```
build.sh       orchestration (clone -> patch -> build -> stage)
files/         patches and setup scripts, kept in FreeBSD port style
work/          source trees, caches and step stamps (gitignored)
distfiles/     bun install cache, shared across builds (gitignored)
stage/         output binary (gitignored)
```

Useful environment overrides for `build.sh`: `WORK=`, `STAGE=`, `CACHE=`
(defaults: `./work`, `./stage`, `./distfiles/bun-cache`). Steps are stamped in
`work/.stamps/`; delete a stamp (or the whole tree) to redo a step.

## Upgrading to a new opencode release

1. Bump `OPENCODE_TAG` in `build.sh` (and `OPENTUI_REV`/`FFF_VERSION`/
   `GHOSTTY_REV` if they moved — opencode pins opentui/fff in its lockfile,
   check `packages/*/package.json`).
2. `rm -rf work` and re-run. Expect to regenerate patches that no longer
   apply: the setup scripts locate their patch points by anchors, which drift
   across releases; the `patch-*` files apply with `patch -p0 -d work/opencode`.
3. Regenerate drifted patches with
   `git -C work/opencode diff --no-prefix -- <path>` while the tree is patched.

## arm64 notes (untested)

The pipeline is arch-parametrised and OpenTUI/fff/pty build for aarch64 the
same way, but the web UI's native Rust bindings (lightningcss, rolldown,
tailwind-oxide) have no `freebsd-arm64` npm builds. Fallback to the WASM
variants: `bun install` in a scratch dir with `files/webui-wasm-package.json`
and create a `lightningcss-freebsd-arm64` shim package whose `index.js` is
`module.exports = require("lightningcss-wasm")`. None of this is needed on
amd64, where the native binding packages install directly from npm.

## Feeding the FreeBSD port

The `patch-*` files and setup scripts are deliberately in the style used by
`misc/opencode` (samm@ maintains it). When a new opencode lands here, the same
files can be dropped into the port with minimal changes — that is the intended
flow for keeping the port current.
