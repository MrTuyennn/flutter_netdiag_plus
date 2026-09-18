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
