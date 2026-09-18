/// Models cho module đo lường mạng.
///
/// Không phụ thuộc package ngoài — chỉ dart core.
library;

/// Trạng thái của một bước đo.
enum DiagStatus {
  /// Chưa chạy.
  pending,

  /// Đang chạy.
  running,

  /// Xong, số đo tốt.
  success,

  /// Xong nhưng chậm hơn ngưỡng cho phép.
  warning,

  /// Lỗi / timeout.
  failed,

  /// Bỏ qua (không khả dụng trên thiết bị này).
  skipped,
}

extension DiagStatusX on DiagStatus {
  bool get isTerminal =>
      this == DiagStatus.success ||
      this == DiagStatus.warning ||
      this == DiagStatus.failed ||
      this == DiagStatus.skipped;

  bool get isOk => this == DiagStatus.success || this == DiagStatus.warning;
}

/// Một dòng trong bảng "Đo lường chi tiết".
class DiagStep {
  const DiagStep({
    required this.id,
    required this.label,
    this.status = DiagStatus.pending,
    this.value,
    this.detail,
    this.elapsed,
  });

  /// Khoá ổn định, dùng để update đúng dòng.
  final String id;

  /// Nhãn hiển thị bên trái: "DNS Lookup", "Google", ...
  final String label;

  final DiagStatus status;

  /// Text hiển thị bên phải: "10ms → 27.118.16.1", "112ms (HTTP 200)".
  final String? value;

  /// Thông tin phụ / message lỗi, hiển thị dưới dạng dòng nhỏ khi có.
  final String? detail;

  /// Thời gian đo được (nếu bước đó có ý nghĩa thời gian).
  final Duration? elapsed;

  DiagStep copyWith({
    DiagStatus? status,
    String? value,
    String? detail,
    Duration? elapsed,
  }) {
    return DiagStep(
      id: id,
      label: label,
      status: status ?? this.status,
      value: value ?? this.value,
      detail: detail ?? this.detail,
      elapsed: elapsed ?? this.elapsed,
    );
  }

  @override
  String toString() => 'DiagStep($id, $status, $value)';
}

/// Một đích ping bên ngoài (Google, Viettel IDC, VnExpress...).
class PingTarget {
  const PingTarget({
    required this.id,
    required this.label,
    required this.host,
    this.port = 443,
  });

  final String id;
  final String label;
  final String host;
  final int port;
}

/// Kết quả tổng của một lần chạy.
class DiagReport {
  const DiagReport({
    required this.steps,
    required this.startedAt,
    required this.finishedAt,
  });

  final List<DiagStep> steps;
  final DateTime startedAt;
  final DateTime finishedAt;

  Duration get totalDuration => finishedAt.difference(startedAt);

  bool get hasFailure => steps.any((s) => s.status == DiagStatus.failed);

  bool get hasWarning => steps.any((s) => s.status == DiagStatus.warning);

  /// Dump gọn để log / gửi lên server khi user báo lỗi mạng.
  Map<String, dynamic> toJson() => {
    'startedAt': startedAt.toIso8601String(),
    'totalMs': totalDuration.inMilliseconds,
    'steps': [
      for (final s in steps)
        {
          'id': s.id,
          'status': s.status.name,
          'value': s.value,
          'detail': s.detail,
          'ms': s.elapsed?.inMilliseconds,
        },
    ],
  };
}
