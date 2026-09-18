# flutter_netdiag_plus

Đo lường mạng chi tiết cho Flutter: DNS lookup, TCP connect, HTTP RTT, ping
nhiều đích, traceroute. Toàn bộ phần đo dùng `dart:io` thuần — chỉ traceroute
cần code native, và code đó đã đóng gói sẵn trong package, tự build khi bạn
`flutter pub get` — không cần thao tác Xcode/Gradle thủ công.

## Cài đặt

```yaml
dependencies:
  flutter_netdiag_plus: ^0.1.0
```

```bash
flutter pub get
```

## Quyền cần khai báo

**Android** — package tự merge `INTERNET` permission vào app dùng nó, không
cần khai báo gì thêm.

**iOS** — không cần khai báo gì. `Socket.connect` không đụng ATS (ATS chỉ chi
phối `NSURLSession`). Chỉ khi ping host trong LAN mới cần thêm
`NSLocalNetworkUsageDescription` vào `Info.plist` của app.

**macOS** — app cần bật `com.apple.security.network.client` trong
`macos/Runner/*.entitlements` nếu dùng App Sandbox.

## Dùng

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

Không cần UI — hợp cho nút "Báo lỗi mạng", đính `report.toJson()` vào ticket:

```dart
final report = await NetworkDiagnosticService(host: 'api.example.com').runOnce();
await api.sendTicket(diagnostics: report.toJson());
```

## Vài quyết định thiết kế

**Ping bằng TCP connect, không phải ICMP.** ICMP raw socket cần native code,
Android 10+ siết, và nhiều firewall drop ICMP nhưng vẫn cho TCP 443 qua — tức
là ICMP fail giả trong khi mạng vẫn tốt. Thời gian bắt tay TCP cũng sát với độ
trễ thật mà app cảm nhận, vì app cũng nói chuyện qua TCP/TLS chứ không ping ai
cả.

**Lấy min chứ không lấy trung bình.** Nhiễu mạng chỉ làm số đo *tăng*, nên lần
nhanh nhất trong 3 lần thử là ước lượng sát nhất của độ trễ thật. Trung bình bị
một cú spike kéo lệch ngay.

**DNS sẽ ra ~0ms từ lần đo thứ 2.** `InternetAddress.lookup` đi qua resolver
của OS nên có cache. Muốn số thật thì thay bằng DoH query thẳng 1.1.1.1 /
8.8.8.8 — chỗ cần sửa có comment sẵn trong service.

## Traceroute

Cắm vào qua `hopResolver`:

```dart
NetworkDiagnosticService(
  host: 'api.example.com',
  hopResolver: (host) async {
    final result = await createTraceroute().trace(host);
    return result.hops.isEmpty ? null : result.hopCount;
  },
)
```

Hoặc dùng độc lập:

```dart
final result = await createTraceroute().trace('example.com');
for (final hop in result.hops) {
  print(hop);          // "3  10.1.2.3  12.3ms"  hoặc  "4  *"
}
```

`reachedDestination == false` nghĩa là hết `maxHops` mà chưa chạm đích — số hop
khi đó chỉ là **cận dưới**, UI hiện "≥ N chặng".

### Cách làm trên từng nền tảng

| Nền tảng      | Cách                                                    |
|---------------|-----------------------------------------------------------|
| Android       | lặp `ping -c1 -t <ttl>`, fallback native NDK (ICMP ping-socket) nếu exec bị chặn |
| Linux / macOS | gọi thẳng `traceroute -n`                               |
| Windows       | gọi `tracert -d`                                        |
| iOS           | native Swift (UDP probe + socket ICMP thụ động)         |

### iOS: UDP probe + ICMP thụ động

1. Gửi probe bằng UDP tới port `33434+ttl`, đặt `IP_TTL` tăng dần.
2. Một socket ICMP **riêng, chỉ đọc không gửi**, nhận ICMP Time Exceeded.
3. Match reply với probe bằng port đích nằm trong payload lồng bên trong.

Không dùng biến thể ICMP Echo + `IP_TTL` như trên Linux, vì `setsockopt(IP_TTL)`
trên `SOCK_DGRAM` ICMP của Darwin hoạt động không nhất quán, và việc match
reply phải dựa vào nội dung payload lồng — dễ sai. Dùng UDP thì port đích
chính là mã số của probe, match chuẩn xác.

### Android: ping -t, fallback NDK khi exec bị chặn

Android không có binary `traceroute`, nhưng `ping` của toybox có cờ `-t TTL` —
gửi TTL tăng dần rồi đọc ICMP Time Exceeded chính là thuật toán traceroute.

Một số ROM (chủ yếu ROM Trung Quốc) chặn `execve` ở tầng SELinux/seccomp —
`Process.run('ping', ...)` ném `ProcessException` ngay lập tức. Package tự
phát hiện bằng self-ping loopback, và nếu bị chặn thì chuyển sang code C
trong `android/src/main/cpp/traceroute.c`:

- Mở **ICMP ping-socket** (`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`) —
  không phải raw socket nên không cần root, Android cho phép nhờ sysctl
  `net.ipv4.ping_group_range`.
- TTL tăng dần qua `setsockopt(IP_TTL)`.
- ICMP Time Exceeded từ router giữa đường đọc qua
  `recvmsg(fd, &msg, MSG_ERRQUEUE)` sau khi bật `IP_RECVERR` — API này không
  có trong `android.system.Os` của Android SDK nên bắt buộc viết native
  (NDK/JNI), không làm thuần Kotlin được.

Build tự động qua Gradle (`externalNativeBuild { cmake { ... } }`), không cần
thao tác gì thêm.

### Giới hạn cần biết

- **Chặng `*` là bình thường.** Nhiều router cố tình không trả ICMP Time
  Exceeded, hoặc rate-limit nó. Traceroute nào cũng gặp, không phải bug.
- **Chậm.** 30 hop × 1.5s = tệ nhất ~45 giây. Nếu chỉ cần số hop, hạ `maxHops`
  xuống 20 là đủ cho hầu hết đích trong nước.
- **Đo qua mobile data có thể trả về ít hop hơn thực tế** — CGNAT của nhà mạng
  giấu bớt chặng.
- **Chỉ IPv4.** Đích IPv6 sẽ resolve fail.

## Tuỳ biến giao diện

Mọi màu sắc nằm trong `DiagTheme`:

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

## Ví dụ

Xem `example/` trong repo để có app demo đầy đủ (ô nhập host + panel + copy
JSON).
