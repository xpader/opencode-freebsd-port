Advertise a connectable URL in service.json for wildcard binds.

The service registration records HttpServer.formatAddress() of the bound
socket address. When the user configures hostname "0.0.0.0" (or "::") so the
service listens on all interfaces, the URL written to service.json and shown
by `opencode service status` therefore contains the literal wildcard address.
Connecting to http://0.0.0.0:<port>/ only works on Linux, where the kernel
historically treats 0.0.0.0 as 127.0.0.1; on FreeBSD connect() fails with
ENETUNREACH, so status reports a running server as "stopped" and
`opencode service start` times out waiting for the background service.

Advertise loopback instead of the wildcard, mirroring the RemoteTunnel target
selection in server-process.ts; the actual bind address is untouched, so the
server still listens on all interfaces.

--- packages/cli/src/services/service-registration.ts.orig
+++ packages/cli/src/services/service-registration.ts
@@ -24,7 +24,7 @@ export const register = Effect.fnUntraced(function* (options: {
   const info = {
     id: options.id,
     version: OPENCODE_VERSION,
-    url: HttpServer.formatAddress(options.address),
+    url: HttpServer.formatAddress(advertised(options.address)),
     pid: process.pid,
     password: options.password,
   }
@@ -77,3 +77,13 @@ export const register = Effect.fnUntraced(function* (options: { {
     Effect.ignore,
   )
 })
+
+// A wildcard bind is not a connectable address outside Linux (whose kernel
+// historically treats 0.0.0.0 as loopback), so advertise loopback instead.
+function advertised(address: NetAddress.SocketAddress): NetAddress.SocketAddress {
+  if (!NetAddress.isInetAddress(address)) return address
+  const bound = NetAddress.formatIp(address.address)
+  if (bound === "0.0.0.0") return NetAddress.inetAddressFromIpStringUnsafe("127.0.0.1", address.port)
+  if (bound === "::") return NetAddress.inetAddressFromIpStringUnsafe("::1", address.port)
+  return address
+}
