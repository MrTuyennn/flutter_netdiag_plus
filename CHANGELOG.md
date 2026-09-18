## 0.1.0

* Bản đầu tiên: DNS lookup, TCP connect, HTTP RTT, ping nhiều đích, traceroute.
* Traceroute native trên iOS (Swift, ICMP datagram socket).
* Traceroute native trên Android qua NDK (ICMP ping-socket, `recvmsg(MSG_ERRQUEUE)`),
  fallback tự động khi exec binary `ping` bị ROM chặn.
* `NetworkDiagnosticPanel` — widget sẵn để nhúng vào app.
