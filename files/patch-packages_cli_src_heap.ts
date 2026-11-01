Do not register the SIGUSR1 heap-stats handler on FreeBSD.

opencode's heap module installs a process.on("SIGUSR1") handler so external
tools can request a heap snapshot on demand. On FreeBSD, bun's bundled
JavaScriptCore uses SIGUSR1 internally for VM thread suspension (stop-the-world
GC): taking over the signal with process.on() discards JSC's handler, and the
next GC suspends threads that then wait forever on the umtx handshake,
deadlocking the whole process (it stops responding even to SIGTERM; verified
with ktrace, which shows the process hanging right after sending itself
SIGUSR1).

Skip the handler on FreeBSD, as is already done for win32. This mirrors the
protection that the lang/bun port applies to bun itself.

--- packages/cli/src/heap.ts.orig
+++ packages/cli/src/heap.ts
@@ -4,7 +4,9 @@ import { Effect, Queue } from "effect"
 
 export const listen = Effect.gen(function* () {
   const global = yield* Global.Service
-  if (process.platform === "win32") return
+  // FreeBSD: JSC uses SIGUSR1 for thread suspension; registering a handler
+  // overrides it and deadlocks the VM on the next stop-the-world GC.
+  if (process.platform === "win32" || process.platform === "freebsd") return
   const signals = yield* Queue.dropping<void>(1)
   yield* Effect.acquireRelease(
     Effect.sync(() => {
