/// Đo lường mạng chi tiết cho Flutter — DNS lookup, TCP connect, HTTP RTT,
/// ping nhiều đích, traceroute. Toàn bộ phần đo dùng `dart:io` thuần, chỉ
/// traceroute cần code native (Android NDK, iOS Swift) đi kèm sẵn trong
/// package — không cần thao tác thủ công gì thêm sau khi `flutter pub get`.
library;

export 'network_diagnostic/network_diagnostic_models.dart';
export 'network_diagnostic/network_diagnostic_panel.dart';
export 'network_diagnostic/network_diagnostic_service.dart';
export 'network_diagnostic/traceroute/traceroute.dart'
    show Traceroute, TraceHop, TracerouteResult, createTraceroute;
