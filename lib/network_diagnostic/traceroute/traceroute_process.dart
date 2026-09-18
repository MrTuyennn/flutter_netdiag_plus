/// Traceroute bằng cách gọi binary hệ thống — Android, Linux, macOS, Windows.
///
/// iOS KHÔNG dùng được file này: app sandbox không cho fork/exec, `Process.run`
/// sẽ ném lỗi. Xem `traceroute_ios.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'traceroute.dart';
import 'traceroute_android_native.dart';

final _ipRegex = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b');
final _timeRegex = RegExp(r'time[=<]\s*([\d.]+)\s*ms', caseSensitive: false);

/// Resolve host → IP, để biết chặng cuối đã phải là đích chưa.
Future<String?> _resolve(String host) async {
  if (_ipRegex.hasMatch(host) && host.split('.').length == 4) return host;
  try {
    final addrs = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 5));
    return addrs.isEmpty ? null : addrs.first.address;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Android: lặp `ping -t <ttl>`
// ---------------------------------------------------------------------------

/// Android không có sẵn binary `traceroute`, nhưng `ping` của toybox có cờ
/// `-t TTL`. Gửi TTL tăng dần, router nào hết TTL sẽ trả ICMP Time Exceeded và
/// `ping` in ra "From \<ip\> ... Time to live exceeded" — đúng cơ chế traceroute.
class PingTtlTraceroute extends Traceroute {
  const PingTtlTraceroute();

  @override
  bool get isSupported => true;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async {
    if (!await _execAvailable()) {
      // ROM chặn exec `ping` — dùng traceroute native (ICMP ping-socket qua
      // NDK, xem traceroute_android_native.dart) thay vì trả rỗng.
      return const AndroidNativeTraceroute().trace(
        host,
        maxHops: maxHops,
        perHopTimeout: perHopTimeout,
      );
    }

    final destination = await _resolve(host);
    final hops = <TraceHop>[];
    var reached = false;

    for (var ttl = 1; ttl <= maxHops; ttl++) {
      final hop = await _probe(host, ttl, perHopTimeout, destination);
      hops.add(hop);
      if (hop.isDestination) {
        reached = true;
        break;
      }
    }

    return TracerouteResult(hops: hops, reachedDestination: reached);
  }

  /// `ping` bị exec-chặn ném ProcessException ngay lập tức thay vì chạy rồi
  /// timeout — self-ping tới loopback để phân biệt hai trường hợp đó.
  Future<bool> _execAvailable() async {
    for (final binary in const ['/system/bin/ping', 'ping']) {
      try {
        await Process.run(binary, [
          '-c',
          '1',
          '-w',
          '1',
          '127.0.0.1',
        ]).timeout(const Duration(seconds: 2));
        return true;
      } on ProcessException {
        continue;
      } on TimeoutException {
        return true; // binary chạy được, chỉ chậm/không phản hồi
      }
    }
    return false;
  }

  Future<TraceHop> _probe(
    String host,
    int ttl,
    Duration timeout,
    String? destination,
  ) async {
    final seconds = (timeout.inMilliseconds / 1000).ceil().clamp(1, 10);
    final sw = Stopwatch()..start();

    ProcessResult? result;
    for (final binary in const ['/system/bin/ping', 'ping']) {
      try {
        result = await Process.run(binary, [
          '-c',
          '1',
          '-t',
          '$ttl',
          '-W',
          '$seconds',
          host,
        ]).timeout(timeout + const Duration(seconds: 2));
        break;
      } on ProcessException {
        continue; // thử binary tiếp theo
      } on TimeoutException {
        return TraceHop(ttl: ttl);
      }
    }
    sw.stop();

    if (result == null) return TraceHop(ttl: ttl);

    final output = '${result.stdout}\n${result.stderr}';
    return _parsePingOutput(
      output: output,
      ttl: ttl,
      elapsedMs: sw.elapsedMicroseconds / 1000,
      destination: destination,
    );
  }
}

/// Tách riêng để test được mà không cần chạy process thật.
TraceHop _parsePingOutput({
  required String output,
  required int ttl,
  required double elapsedMs,
  String? destination,
}) {
  final lower = output.toLowerCase();

  // Chặng trung gian: "From 192.168.1.1 icmp_seq=1 Time to live exceeded"
  if (lower.contains('time to live exceeded') ||
      lower.contains('ttl exceeded')) {
    final line = output
        .split('\n')
        .firstWhere(
          (l) => l.toLowerCase().contains('exceeded'),
          orElse: () => output,
        );
    return TraceHop(
      ttl: ttl,
      address: _ipRegex.firstMatch(line)?.group(1),
      rttMs: elapsedMs,
    );
  }

  // Tới đích: "64 bytes from 142.250.66.110: icmp_seq=1 ttl=113 time=12.3 ms"
  if (lower.contains('bytes from')) {
    final line = output
        .split('\n')
        .firstWhere(
          (l) => l.toLowerCase().contains('bytes from'),
          orElse: () => output,
        );
    final rtt = _timeRegex.firstMatch(line)?.group(1);
    return TraceHop(
      ttl: ttl,
      address: _ipRegex.firstMatch(line)?.group(1) ?? destination,
      rttMs: rtt != null ? double.tryParse(rtt) : elapsedMs,
      isDestination: true,
    );
  }

  // "From 10.0.0.1 icmp_seq=1 Destination Host Unreachable" — coi như tới cuối
  // đường đi được, không đi tiếp được nữa.
  if (lower.contains('unreachable')) {
    final line = output
        .split('\n')
        .firstWhere(
          (l) => l.toLowerCase().contains('unreachable'),
          orElse: () => output,
        );
    return TraceHop(
      ttl: ttl,
      address: _ipRegex.firstMatch(line)?.group(1),
      rttMs: elapsedMs,
      isDestination: true,
    );
  }

  // Không ai trả lời — chặng im lặng, đi tiếp.
  return TraceHop(ttl: ttl);
}

// ---------------------------------------------------------------------------
// Linux / macOS: binary traceroute có sẵn
// ---------------------------------------------------------------------------

class UnixTraceroute extends Traceroute {
  const UnixTraceroute();

  @override
  bool get isSupported => true;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async {
    final destination = await _resolve(host);
    final waitSec = (perHopTimeout.inMilliseconds / 1000).ceil().clamp(1, 10);

    final ProcessResult result;
    try {
      result = await Process.run('traceroute', [
        '-n',
        '-q',
        '1',
        '-w',
        '$waitSec',
        '-m',
        '$maxHops',
        host,
      ]).timeout(perHopTimeout * maxHops + const Duration(seconds: 5));
    } on ProcessException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on TimeoutException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    }

    return _parseHopLines('${result.stdout}', destination);
  }
}

// ---------------------------------------------------------------------------
// Windows: tracert
// ---------------------------------------------------------------------------

class WindowsTraceroute extends Traceroute {
  const WindowsTraceroute();

  @override
  bool get isSupported => true;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async {
    final destination = await _resolve(host);

    final ProcessResult result;
    try {
      result = await Process.run('tracert', [
        '-d',
        '-h',
        '$maxHops',
        '-w',
        '${perHopTimeout.inMilliseconds}',
        host,
      ]).timeout(perHopTimeout * maxHops + const Duration(seconds: 5));
    } on ProcessException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on TimeoutException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    }

    return _parseHopLines('${result.stdout}', destination);
  }
}

/// Parse output dạng bảng của cả `traceroute` lẫn `tracert`:
/// mỗi dòng bắt đầu bằng số thứ tự chặng, theo sau là IP và/hoặc `*`.
TracerouteResult _parseHopLines(String output, String? destination) {
  final hops = <TraceHop>[];
  final lineRegex = RegExp(r'^\s*(\d+)\s+(.*)$');

  for (final line in output.split('\n')) {
    final match = lineRegex.firstMatch(line);
    if (match == null) continue;

    final ttl = int.parse(match.group(1)!);
    final rest = match.group(2)!;
    final ip = _ipRegex.firstMatch(rest)?.group(1);

    double? rtt;
    final msMatch = RegExp(r'([\d.]+)\s*ms').firstMatch(rest);
    if (msMatch != null) rtt = double.tryParse(msMatch.group(1)!);

    hops.add(
      TraceHop(
        ttl: ttl,
        address: ip,
        rttMs: rtt,
        isDestination: ip != null && ip == destination,
      ),
    );
  }

  final reached = hops.isNotEmpty && hops.last.isDestination;
  return TracerouteResult(hops: hops, reachedDestination: reached);
}
