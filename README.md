# flutter_netdiag_plus

Detailed network diagnostics for Flutter: DNS lookup, TCP connect, HTTP RTT,
multi-target ping, traceroute. All measurements use pure `dart:io` — only
traceroute needs native code, and that code ships pre-packaged with the
plugin and builds automatically on `flutter pub get`, no manual Xcode/Gradle
steps required.

## Install

```yaml
dependencies:
  flutter_netdiag_plus: ^0.1.0
```

```bash
flutter pub get
```

## Permissions

**Android** — the package automatically merges the `INTERNET` permission
into the app that uses it, nothing else to declare.

**iOS** — nothing to declare. `Socket.connect` doesn't go through ATS (ATS
only governs `NSURLSession`). Only pinging a LAN host requires adding
`NSLocalNetworkUsageDescription` to the app's `Info.plist`.

**macOS** — the app needs to enable `com.apple.security.network.client` in
`macos/Runner/*.entitlements` if it uses App Sandbox.

## Usage

```dart
import 'package:flutter_netdiag_plus/flutter_netdiag_plus.dart';

NetworkDiagnosticPanel(
  service: NetworkDiagnosticService(
    host: 'api.example.com',
    port: 443,
    externalTargets: const [
      PingTarget(id: 'google', label: 'Google', host: 'google.com'),
      PingTarget(id: 'cloudflare', label: 'Cloudflare', host: 'cloudflare.com'),
    ],
  ),
)
```

No UI needed — fits a "Report network issue" button, attach
`report.toJson()` to the ticket:

```dart
final report = await NetworkDiagnosticService(host: 'api.example.com').runOnce();
await api.sendTicket(diagnostics: report.toJson());
```

## Some design decisions

**Ping via TCP connect, not ICMP.** Raw ICMP sockets need native code,
Android 10+ restricts them, and many firewalls drop ICMP while still
letting TCP 443 through — meaning ICMP reports a false failure while the
network is actually fine. TCP handshake time is also close to the real
latency an app feels, since the app itself talks over TCP/TLS, not ICMP.

**Takes the min, not the average.** Network noise can only make a
measurement *higher*, so the fastest of 3 attempts is the closest estimate
of the true latency. An average gets skewed by a single spike.

**DNS will read ~0ms from the 2nd measurement on.** `InternetAddress.lookup`
goes through the OS resolver, which caches results. For a true reading,
swap in a direct DoH query to 1.1.1.1 / 8.8.8.8 — the spot to change already
has a comment in the service.

## Traceroute

Plug it in via `hopResolver`:

```dart
NetworkDiagnosticService(
  host: 'api.example.com',
  hopResolver: (host) async {
    final result = await createTraceroute().trace(host);
    return result.hops.isEmpty ? null : result.hopCount;
  },
)
```

Or use it standalone:

```dart
final result = await createTraceroute().trace('example.com');
for (final hop in result.hops) {
  print(hop);          // "3  10.1.2.3  12.3ms"  or  "4  *"
}
```

`reachedDestination == false` means `maxHops` ran out before reaching the
target — the hop count is then just a **lower bound**, and the UI shows
"≥ N hops".

### Platform-specific approach

| Platform      | Approach                                                   |
|---------------|--------------------------------------------------------------|
| Android       | loops `ping -c1 -t <ttl>`, falls back to native NDK (ICMP ping-socket) if exec is blocked |
| Linux / macOS | calls `traceroute -n` directly                               |
| Windows       | calls `tracert -d`                                            |
| iOS           | native Swift (UDP probe + passive ICMP socket)                |

### iOS: UDP probe + passive ICMP

1. Sends a UDP probe to port `33434+ttl`, with increasing `IP_TTL`.
2. A **separate, receive-only** ICMP socket picks up the ICMP Time Exceeded
   reply.
3. Matches the reply to the probe using the destination port embedded in
   the nested payload.

Doesn't use the ICMP Echo + `IP_TTL` variant used on Linux, because
`setsockopt(IP_TTL)` on Darwin's `SOCK_DGRAM` ICMP socket behaves
inconsistently, and matching a reply would then have to rely on the nested
payload content — error-prone. With UDP, the destination port *is* the
probe's id, so matching is exact.

### Android: `ping -t`, fallback to NDK when exec is blocked

Android has no `traceroute` binary, but toybox's `ping` has a `-t TTL`
flag — sending increasing TTLs and reading the ICMP Time Exceeded replies
*is* the traceroute algorithm.

Some ROMs (mostly Chinese ROMs) block `execve` at the SELinux/seccomp
layer — `Process.run('ping', ...)` throws a `ProcessException` right away.
The package detects this automatically via a loopback self-ping, and falls
back to the C code in `android/src/main/cpp/traceroute.c` when blocked:

- Opens an **ICMP ping-socket** (`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`)
  — not a raw socket, so no root needed; Android allows it via the
  `net.ipv4.ping_group_range` sysctl.
- Increases TTL via `setsockopt(IP_TTL)`.
- Reads the ICMP Time Exceeded from routers along the path via
  `recvmsg(fd, &msg, MSG_ERRQUEUE)` after enabling `IP_RECVERR` — this API
  isn't exposed by `android.system.Os` in the Android SDK, so it has to be
  written natively (NDK/JNI); it can't be done in pure Kotlin.

Builds automatically via Gradle (`externalNativeBuild { cmake { ... } }`),
no extra steps needed.

### Known limitations

- **A `*` hop is normal.** Many routers deliberately don't reply with ICMP
  Time Exceeded, or rate-limit it. Every traceroute implementation runs
  into this — it isn't a bug.
- **Slow.** 30 hops × 1.5s is a worst case of ~45 seconds. If you only need
  the hop count, lowering `maxHops` to 20 is enough for most domestic
  targets.
- **Measuring over mobile data can report fewer hops than reality** — the
  carrier's CGNAT hides some hops.
- **IPv4 only.** An IPv6 target will fail to resolve.

## Customizing the UI

All colors live in `DiagTheme`:

```dart
NetworkDiagnosticPanel(
  service: service,
  theme: const DiagTheme(
    background: Color(0xFF12161A),
    success: Color(0xFF22C55E),
    radius: 12,
  ),
)
```

## Example

See `example/` in the repo for a full demo app (host input field + panel +
copy JSON).
