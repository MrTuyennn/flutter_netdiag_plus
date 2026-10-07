/// Traceroute Android qua NDK — dùng khi exec binary `ping` bị chặn (một số
/// ROM Trung Quốc siết `execve`, xem `PingTtlTraceroute._execAvailable` ở
/// `traceroute_process.dart`).
///
/// C code (`android/app/src/main/cpp/traceroute.c`) tự mở ICMP ping-socket
/// (`SOCK_DGRAM, IPPROTO_ICMP`, không cần root — Android cho phép nhờ sysctl
/// `ping_group_range`) và bắt ICMP Time Exceeded qua `recvmsg(MSG_ERRQUEUE)`.
/// API này không có trong `android.system.Os` của Android SDK nên bắt buộc
/// viết native, không làm thuần Kotlin được.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'traceroute.dart';

const _channel = MethodChannel('flutter_netdiag_plus/traceroute_android');

class AndroidNativeTraceroute extends Traceroute {
  const AndroidNativeTraceroute();

  @override
  bool get isSupported => true;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async {
    try {
      final raw = await _channel.invokeMethod<String>('trace', {
        'host': host,
        'maxHops': maxHops,
        'timeoutMs': perHopTimeout.inMilliseconds,
      });

      if (raw == null) {
        return const TracerouteResult(hops: [], reachedDestination: false);
      }

      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        // {"error": "..."} — resolve_failed hoặc socket_failed phía native.
        return const TracerouteResult(hops: [], reachedDestination: false);
      }

      final hops = [
        for (final item in decoded.whereType<Map<String, dynamic>>())
          TraceHop(
            ttl: (item['ttl'] as num?)?.toInt() ?? 0,
            address: item['address'] as String?,
            rttMs: (item['rttMs'] as num?)?.toDouble(),
            isDestination: item['isDestination'] as bool? ?? false,
          ),
      ];

      return TracerouteResult(
        hops: hops,
        reachedDestination: hops.isNotEmpty && hops.last.isDestination,
      );
    } on MissingPluginException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on PlatformException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on FormatException {
      // JSON native trả về bị méo/cắt cụt — coi như không lấy được kết quả
      // thay vì để lỗi parse văng ra ngoài.
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on TypeError {
      // Giá trị trong JSON sai kiểu so với kỳ vọng (ttl/address/rttMs/...).
      return const TracerouteResult(hops: [], reachedDestination: false);
    }
  }
}
