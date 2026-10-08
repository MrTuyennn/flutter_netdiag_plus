## 1.0.2

* `NetworkDiagnosticService.run()` now runs all steps (DNS lookup, TCP
  connect, HTTP RTT, every external ping target, and traceroute)
  concurrently instead of one after another — each step updates its own
  status/result as soon as it finishes, instead of waiting for the steps
  listed above it to finish first. Total run time drops from the sum of
  every step's duration to roughly the duration of the slowest one.
* TCP Connect no longer reuses the `InternetAddress` resolved by the DNS
  Lookup step — it resolves the host itself via `Socket.connect(host, port)`
  so it is fully independent and is never skipped or delayed by a slow or
  failing DNS step.
* Example app: fixed a bug where typing a full URL (with `http(s)://` and a
  path) into the host field, or leaving a path in the default host, made
  DNS Lookup fail — the host is now consistently extracted (scheme + path
  stripped) both on first load and when pressing "Đo".

## 1.0.1

* Fix: iOS traceroute checks the `setsockopt(SO_RCVTIMEO)` result instead of
  ignoring it — previously a failed call could leave the ICMP socket with no
  read timeout and hang `recvfrom()` (and the awaiting Dart `Future`)
  indefinitely.
* Fix: Android native traceroute (`traceroute.c`) now verifies the ICMP
  echo id/sequence on every reply (both the direct echo reply and the
  `MSG_ERRQUEUE` Time Exceeded/Unreachable path) before accepting it, so a
  delayed reply from an earlier hop can no longer be misattributed to the
  current TTL under packet reordering/jitter.
* Fix: Android native traceroute no longer leaves an unbounded/dangling
  allocation on `malloc`/`realloc` failure — it now fails gracefully with an
  `alloc_failed` error instead of crashing the native process.
* Fix: Android native traceroute clamps `maxHops` to `[1, 64]`, matching the
  iOS implementation, so the same Dart call no longer behaves differently
  per platform.
* Fix: `FlutterNetdiagPlusPlugin` (Android) no longer delivers a
  `MethodChannel.Result` after the engine has detached (e.g. hot restart,
  activity recreation), and attempts to interrupt an in-flight trace on
  detach instead of letting it run to completion against a dead channel.
* Fix: both Android and iOS Dart traceroute wrappers now catch malformed
  native results (`FormatException`/`TypeError`) and degrade to an empty
  result instead of throwing uncaught.

## 0.1.0

* First release of `flutter_netdiag_plus`.
* `NetworkDiagnosticService`: measures DNS lookup, TCP connect, HTTP RTT, and
  multi-target ping (`externalTargets`) using pure `dart:io` — no extra
  setup required.
* Ping is measured via TCP connect (not ICMP) — takes the `min` of several
  samples to stay close to the latency an app actually experiences, and to
  avoid false negatives from firewalls that drop ICMP but allow TCP.
* Traceroute plugs in via `hopResolver`, or can be used standalone through
  `createTraceroute()`:
  * iOS: native Swift (UDP probe + passive ICMP socket).
  * Android: iterative `ping -t TTL`, with automatic fallback to native C
    code built via the NDK (ICMP ping-socket, `recvmsg(MSG_ERRQUEUE)`) when
    the ROM blocks `execve`.
* `NetworkDiagnosticPanel` — a ready-to-embed widget, themeable via
  `DiagTheme`.
* Can also be used headless: `NetworkDiagnosticService(...).runOnce()`
  returns a report whose `toJson()` output can be attached to a bug report
  ticket.
* Supports Android and iOS.
