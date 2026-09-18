/// Traceroute trên iOS — gọi sang Swift qua MethodChannel.
///
/// iOS không cho app fork/exec nên không mượn được binary hệ thống. Bù lại,
/// iOS CHO PHÉP mở ICMP datagram socket không cần entitlement
/// (`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`) — đủ để tự dựng traceroute.
///
/// Code native nằm ở `ios_native/Traceroute.swift`, cách gắn xem README.
library;

import 'package:flutter/services.dart';

import 'traceroute.dart';

const _channel = MethodChannel('flutter_netdiag_plus/traceroute');

class IosTraceroute extends Traceroute {
  const IosTraceroute();

  @override
  bool get isSupported => true;

  @override
  Future<TracerouteResult> trace(
    String host, {
    int maxHops = 30,
    Duration perHopTimeout = const Duration(milliseconds: 1500),
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'trace',
        {
          'host': host,
          'maxHops': maxHops,
          'timeoutMs': perHopTimeout.inMilliseconds,
        },
      );

      if (raw == null) {
        return const TracerouteResult(hops: [], reachedDestination: false);
      }

      final hops = [
        for (final item in raw)
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
      // Chưa gắn Traceroute.swift vào Runner — coi như không khả dụng thay vì
      // ném lỗi đỏ ra UI.
      return const TracerouteResult(hops: [], reachedDestination: false);
    } on PlatformException {
      return const TracerouteResult(hops: [], reachedDestination: false);
    }
  }
}
