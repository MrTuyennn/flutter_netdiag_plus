/// Đo lường mạng chi tiết bằng dart:io thuần — không cần package ngoài.
///
/// Các bước:
///   1. DNS Lookup        — InternetAddress.lookup
///   2. TCP Connect        — Socket.connect tới host:port
///   3. Server HTTP RTT    — HttpClient GET, đo tới lúc nhận response header
///   4..n. Ping ngoài      — TCP ping (Socket.connect) tới từng đích
///   cuối. Traceroute      — chỉ chạy khi bạn cắm [hopResolver] vào
///
/// Tại sao TCP ping mà không phải ICMP:
///   - ICMP raw socket cần native code, Android 10+ siết, nhiều firewall drop
///     ICMP nhưng vẫn cho TCP 443 đi qua → ICMP fail giả.
///   - Số đo TCP connect sát với trải nghiệm thật của app hơn (app cũng nói
///     chuyện qua TCP/TLS chứ không ping ai cả).
library;

import 'dart:async';
import 'dart:io';

import 'network_diagnostic_models.dart';

/// Hàm trả về số hop tới đích, hoặc null nếu không đo được.
///
/// Dart thuần không làm traceroute được (cần raw ICMP socket). Ba cách cắm vào:
///
///   1. Backend: gọi API của bạn, server chạy `traceroute`/`mtr` rồi trả số hop.
///   2. dart_ping: ICMP reply có TTL, số hop ≈ (128|64) - ttl.
///   3. Native plugin tự viết (Android NDK setsockopt IP_TTL / iOS SimplePing).
///
/// Để null → bước traceroute hiện trạng thái "không khả dụng" thay vì bịa số.
typedef HopResolver = Future<int?> Function(String host);

/// Hàm cập nhật trạng thái một step theo id, dùng trong các bước đo song song.
typedef _StepSetter = void Function(
  String id,
  DiagStep Function(DiagStep) update,
);

class NetworkDiagnosticService {
  NetworkDiagnosticService({
    required this.host,
    this.port = 443,
    this.httpUri,
    this.externalTargets = defaultTargets,
    this.timeout = const Duration(seconds: 5),
    this.pingAttempts = 3,
    this.pingGap = const Duration(milliseconds: 150),
    this.serverWarnAbove = const Duration(milliseconds: 500),
    this.externalWarnAbove = const Duration(milliseconds: 400),
    this.hopResolver,
    this.traceTimeout = const Duration(seconds: 60),
  }) : assert(pingAttempts > 0);

  /// Host của server bạn, ví dụ 'api.example.com'.
  final String host;

  /// Port dùng cho bước TCP Connect.
  final int port;

  /// URL dùng cho bước HTTP RTT. Bỏ trống → https://$host/.
  final Uri? httpUri;

  final List<PingTarget> externalTargets;

  final Duration timeout;

  /// Số lần thử mỗi đích ping; lấy giá trị nhỏ nhất (loại nhiễu).
  final int pingAttempts;

  /// Nghỉ giữa các lần thử để không bị coi là flood.
  final Duration pingGap;

  final Duration serverWarnAbove;
  final Duration externalWarnAbove;

  final HopResolver? hopResolver;

  /// Traceroute chậm hơn hẳn các bước khác: 30 hop × 1.5s là kịch bản bình
  /// thường, nên nó có timeout riêng thay vì dùng chung [timeout].
  final Duration traceTimeout;

  static const List<PingTarget> defaultTargets = [
    PingTarget(id: 'google', label: 'Google', host: 'google.com'),
    PingTarget(id: 'viettel', label: 'Viettel IDC', host: 'viettelidc.vn'),
    PingTarget(id: 'vnexpress', label: 'VnExpress', host: 'vnexpress.net'),
  ];

  bool _cancelled = false;

  /// Dừng lần chạy hiện tại. Các bước chưa chạy sẽ ở trạng thái pending.
  void cancel() => _cancelled = true;

  /// Danh sách bước ở trạng thái ban đầu — dùng để render skeleton ngay.
  List<DiagStep> buildInitialSteps() => [
    const DiagStep(id: 'dns', label: 'DNS Lookup'),
    DiagStep(id: 'tcp', label: 'TCP Connect (:$port)'),
    const DiagStep(id: 'http', label: 'Server HTTP RTT'),
    for (final t in externalTargets) DiagStep(id: t.id, label: t.label),
    const DiagStep(id: 'traceroute', label: 'Traceroute'),
  ];

  /// Chạy toàn bộ, emit lại cả danh sách sau mỗi thay đổi.
  ///
  /// Mọi bước chạy ĐỒNG THỜI (song song), không đợi bước phía trên xong rồi
  /// mới bắt đầu bước sau — bước nào xong trước thì trạng thái của nó cập
  /// nhật trước, bất kể thứ tự hiển thị trong danh sách. Vì vậy TCP Connect
  /// tự resolve host của riêng nó (không ăn theo kết quả DNS Lookup) để
  /// không bị khoá chờ bước DNS.
  ///
  /// Emit cả list (thay vì từng step) để UI chỉ cần một `setState`.
  Stream<List<DiagStep>> run() {
    _cancelled = false;
    final steps = {for (final s in buildInitialSteps()) s.id: s};
    final controller = StreamController<List<DiagStep>>();

    List<DiagStep> snapshot() => steps.values.toList(growable: false);

    void set(String id, DiagStep Function(DiagStep) update) {
      final current = steps[id];
      if (current != null) steps[id] = update(current);
    }

    void emit() {
      if (!controller.isClosed) controller.add(snapshot());
    }

    emit();

    final tasks = <Future<void>>[
      _runDns(set, emit),
      _runTcp(set, emit),
      _runHttp(set, emit),
      for (final target in externalTargets) _runPing(target, set, emit),
      _runTraceroute(set, emit),
    ];

    Future.wait(tasks).whenComplete(() {
      if (!controller.isClosed) controller.close();
    });

    return controller.stream;
  }

  // ---------------------------------------------------------------- DNS
  Future<void> _runDns(_StepSetter set, void Function() emit) async {
    if (_cancelled) return;
    set('dns', (s) => s.copyWith(status: DiagStatus.running));
    emit();

    try {
      final sw = Stopwatch()..start();
      final addrs = await InternetAddress.lookup(host).timeout(timeout);
      sw.stop();
      if (addrs.isEmpty) throw const SocketException('Không có bản ghi A/AAAA');
      final resolved = addrs.first;
      set(
        'dns',
        (s) => s.copyWith(
          status: DiagStatus.success,
          elapsed: sw.elapsed,
          value: '${_ms(sw.elapsed)} → ${resolved.address}',
          detail: addrs.length > 1 ? '${addrs.length} bản ghi' : null,
        ),
      );
      // Lưu ý: InternetAddress.lookup đi qua resolver của OS nên CÓ CACHE —
      // lần đo thứ hai trở đi thường ra ~0ms. Muốn đo DNS thật, dùng DoH
      // (package dns_client) query thẳng 1.1.1.1 / 8.8.8.8.
    } catch (e) {
      set(
        'dns',
        (s) => s.copyWith(
          status: DiagStatus.failed,
          value: 'Thất bại',
          detail: _friendly(e),
        ),
      );
    }
    if (_cancelled) return;
    emit();
  }

  // -------------------------------------------------------- TCP Connect
  Future<void> _runTcp(_StepSetter set, void Function() emit) async {
    if (_cancelled) return;
    set('tcp', (s) => s.copyWith(status: DiagStatus.running));
    emit();

    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      socket.destroy();
      set(
        'tcp',
        (s) => s.copyWith(
          status: sw.elapsed > serverWarnAbove
              ? DiagStatus.warning
              : DiagStatus.success,
          elapsed: sw.elapsed,
          value: _ms(sw.elapsed),
        ),
      );
    } catch (e) {
      set(
        'tcp',
        (s) => s.copyWith(
          status: DiagStatus.failed,
          value: 'Không kết nối được',
          detail: _friendly(e),
        ),
      );
    }
    if (_cancelled) return;
    emit();
  }

  // ----------------------------------------------------------- HTTP RTT
  Future<void> _runHttp(_StepSetter set, void Function() emit) async {
    if (_cancelled) return;
    set('http', (s) => s.copyWith(status: DiagStatus.running));
    emit();

    final uri = httpUri ?? Uri.https(host, '/');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final sw = Stopwatch()..start();
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'NetDiag/1.0');
      // Không cần body, chỉ cần header về là tính xong RTT.
      final response = await request.close().timeout(timeout);
      sw.stop();
      unawaited(response.drain<void>().catchError((_) {}));

      final ok = response.statusCode < 400;
      set(
        'http',
        (s) => s.copyWith(
          status: !ok
              ? DiagStatus.warning
              : (sw.elapsed > serverWarnAbove
                    ? DiagStatus.warning
                    : DiagStatus.success),
          elapsed: sw.elapsed,
          value: '${_ms(sw.elapsed)} (HTTP ${response.statusCode})',
        ),
      );
    } catch (e) {
      set(
        'http',
        (s) => s.copyWith(
          status: DiagStatus.failed,
          value: 'Thất bại',
          detail: _friendly(e),
        ),
      );
    } finally {
      client.close(force: true);
    }
    if (_cancelled) return;
    emit();
  }

  // -------------------------------------------------------- Ping ngoài
  Future<void> _runPing(
    PingTarget target,
    _StepSetter set,
    void Function() emit,
  ) async {
    if (_cancelled) return;
    set(target.id, (s) => s.copyWith(status: DiagStatus.running));
    emit();

    final result = await _tcpPing(target.host, target.port);
    if (_cancelled) return;

    if (result == null) {
      set(
        target.id,
        (s) => s.copyWith(
          status: DiagStatus.failed,
          value: 'Không tới được',
          detail: 'Thử $pingAttempts lần đều lỗi',
        ),
      );
    } else {
      set(
        target.id,
        (s) => s.copyWith(
          status: result > externalWarnAbove
              ? DiagStatus.warning
              : DiagStatus.success,
          elapsed: result,
          value: _ms(result),
        ),
      );
    }
    emit();
  }

  // -------------------------------------------------------- Traceroute
  Future<void> _runTraceroute(_StepSetter set, void Function() emit) async {
    if (_cancelled) return;
    final resolver = hopResolver;
    if (resolver == null) {
      set(
        'traceroute',
        (s) => s.copyWith(
          status: DiagStatus.skipped,
          value: 'Không khả dụng',
          detail: 'Cần backend hoặc native plugin',
        ),
      );
      emit();
      return;
    }

    set('traceroute', (s) => s.copyWith(status: DiagStatus.running));
    emit();
    try {
      final hops = await resolver(host).timeout(traceTimeout);
      set(
        'traceroute',
        (s) => hops == null
            ? s.copyWith(status: DiagStatus.skipped, value: 'Không khả dụng')
            : s.copyWith(status: DiagStatus.success, value: '$hops chặng'),
      );
    } catch (e) {
      set(
        'traceroute',
        (s) => s.copyWith(
          status: DiagStatus.failed,
          value: 'Thất bại',
          detail: _friendly(e),
        ),
      );
    }
    if (_cancelled) return;
    emit();
  }

  /// Chạy một phát rồi trả report — dùng khi muốn log/gửi server, không cần UI.
  Future<DiagReport> runOnce() async {
    final startedAt = DateTime.now();
    var last = buildInitialSteps();
    await for (final snapshot in run()) {
      last = snapshot;
    }
    return DiagReport(
      steps: last,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
    );
  }

  /// TCP ping: đo thời gian bắt tay TCP, lấy lần nhanh nhất trong [pingAttempts].
  ///
  /// Lấy min thay vì trung bình vì nhiễu mạng chỉ làm số đo *tăng*, nên lần
  /// nhanh nhất là ước lượng sát nhất của độ trễ thật.
  Future<Duration?> _tcpPing(String host, int port) async {
    Duration? best;
    for (var i = 0; i < pingAttempts; i++) {
      if (_cancelled) break;
      try {
        final sw = Stopwatch()..start();
        final socket = await Socket.connect(host, port, timeout: timeout);
        sw.stop();
        socket.destroy();
        if (best == null || sw.elapsed < best) best = sw.elapsed;
      } catch (_) {
        // Bỏ qua, thử lần sau.
      }
      if (i < pingAttempts - 1 && !_cancelled) {
        await Future<void>.delayed(pingGap);
      }
    }
    return best;
  }

  static String _ms(Duration d) => '${(d.inMicroseconds / 1000).round()}ms';

  static String _friendly(Object e) {
    if (e is TimeoutException) return 'Quá thời gian chờ';
    if (e is SocketException) {
      final msg = e.osError?.message ?? e.message;
      return msg.isEmpty ? 'Lỗi socket' : msg;
    }
    if (e is HandshakeException) return 'Lỗi bắt tay TLS';
    return e.toString();
  }
}
