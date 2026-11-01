Accept FreeBSD as an opencode-pty target platform.

The CLI build script resolves the @opencode/pty daemon binary for the compile
target and embeds it into the executable. The platform whitelist only covers
darwin, linux and win32, so a freebsd target would silently produce a CLI
without the PTY daemon and every terminal opencode opens would fail.

Add freebsd to the whitelist. @opencode/pty 0.4.0 builds on FreeBSD with a
Ghostty source checkout (see the port recipe for the environment).

--- packages/cli/script/opencode-pty.ts.orig
+++ packages/cli/script/opencode-pty.ts
@@ -19,7 +19,13 @@ const core = createRequire(path.resolve(import.meta.dirname, "../../core/package.
 const pty = createRequire(core.resolve("@opencode/pty/package.json"))
 
 export async function resolveOpencodePty(target: Target): Promise<OpencodePtyAsset | undefined> {
-  if (target.platform !== "darwin" && target.platform !== "linux" && target.platform !== "win32") return undefined
+  if (
+    target.platform !== "darwin" &&
+    target.platform !== "linux" &&
+    target.platform !== "win32" &&
+    target.platform !== "freebsd"
+  )
+    return undefined
   if (target.arch !== "arm64" && target.arch !== "x64") return undefined
 
   const suffix = [target.platform, target.arch, target.platform === "linux" ? (target.libc ?? "glibc") : undefined]
