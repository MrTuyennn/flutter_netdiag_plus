/// Traceroute đa nền tảng.
///
/// | Nền tảng      | Cách làm                                              |
/// |---------------|-------------------------------------------------------|
/// | Android       | `ping -c1 -t <ttl>` lặp theo TTL, parse hop từ stdout  |
/// | Linux / macOS | gọi thẳng `traceroute -n`                             |
/// | Windows       | gọi `tracert -d`                                      |
/// | iOS           | native Swift qua MethodChannel (Process bị sandbox cấm)|
///
/// Dùng:
/// ```dart
/// final result = await createTraceroute().trace('example.com');
/// print('${result.hopCount} chặng, tới đích: ${result.reachedDestination}');
/// ```
library;

import 'dart:io';

import 'traceroute_ios.dart';
import 'traceroute_process.dart';

/// Một chặng trên đường đi.
class TraceHop {
  const TraceHop({
    required this.ttl,
    this.address,
    this.rttMs,
    this.isDestination = false,
  });

  /// TTL của probe, cũng là số thứ tự chặng (1-based).
  final int ttl;

  /// IP của router trả lời. Null = chặng im lặng (`* * *`), rất bình thường —
  /// nhiều router bị cấu hình không trả ICMP Time Exceeded.
  final String? address;

  final double? rttMs;

  /// True khi chặng này chính là đích.
  final bool isDestination;

  bool get isTimeout => address == null;

  @override
  String toString() =>
      '$ttl. ${address ?? '*'}${rttMs != null ? '  ${rttMs!.toStringAsFixed(1)}ms' : ''}';
}

class TracerouteResult {
  const TracerouteResult({
    required this.hops,
    required this.reachedDestination,
  });

  final List<TraceHop> hops;

  /// False khi hết maxHops mà chưa chạm đích — số hop khi đó là cận dưới.
  final bool reachedDestination;

  /// Số chặng. Nếu chưa tới đích thì đây chỉ là "ít nhất bấy nhiêu".
  int get hopCount => hops.length;

  /// Số chặng trả lời được (bỏ qua các chặng `*`).
  int get respondingHops => hops.where((h) => !h.isTimeout).length;

  @override
  String toString() => hops.join('\n');
}

abstract class Traceroute {
  const Traceroute();

  /// False khi nền tảng hiện tại không chạy được — UI nên hiện "Không khả dụng"
  /// thay vì báo lỗi đỏ.
  bool get isSupported;

  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  });
}

/// Chọn implementation theo nền tảng.
Traceroute createTraceroute() {
  if (Platform.isIOS) return const IosTraceroute();
  if (Platform.isAndroid) return const PingTtlTraceroute();
  if (Platform.isLinux || Platform.isMacOS) return const UnixTraceroute();
  if (Platform.isWindows) return const WindowsTraceroute();
  return const UnsupportedTraceroute();
}

class UnsupportedTraceroute extends Traceroute {
  const UnsupportedTraceroute();

  @override
  bool get isSupported => false;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async => const TracerouteResult(hops: [], reachedDestination: false);
}
