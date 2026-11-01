Normalize wildcard addresses in the service incumbent probe URL.

When the user configures hostname "0.0.0.0" (or "::") so the service listens
on all interfaces, serviceURL() built the incumbent probe URL from the raw
bind hostname. Connecting to http://0.0.0.0:<port>/ only works on Linux, where
the kernel historically treats 0.0.0.0 as 127.0.0.1; on FreeBSD connect()
fails with ENETUNREACH, so the probe can never see a running incumbent and
`opencode service start` falls into the address-in-use retry path instead of
attaching to the existing service.

Rewrite wildcard bind hostnames to their loopback equivalents in the probe
URL; the bind address itself is untouched.

--- packages/cli/src/server-process.ts.orig
+++ packages/cli/src/server-process.ts
@@ -217,7 +217,8 @@ const processEffect = Effect.fnUntraced(function* (options: Options) {
 })
 
 function serviceURL(hostname: string, port: number) {
-  return `http://${hostname.includes(":") ? `[${hostname}]` : hostname}:${port}`
+  const host = hostname === "0.0.0.0" ? "127.0.0.1" : hostname === "::" ? "::1" : hostname
+  return `http://${host.includes(":") ? `[${host}]` : host}:${port}`
 }
 
 function truthy(value?: string) {
