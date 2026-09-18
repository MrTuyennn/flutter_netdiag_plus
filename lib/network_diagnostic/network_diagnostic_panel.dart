/// Widget hiển thị bảng "Đo lường chi tiết".
///
/// ```dart
/// NetworkDiagnosticPanel(
///   service: NetworkDiagnosticService(host: 'api.example.com'),
/// )
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'network_diagnostic_models.dart';
import 'network_diagnostic_service.dart';

/// Màu sắc / kiểu chữ của panel. Đổi ở đây là đổi toàn bộ.
class DiagTheme {
  const DiagTheme({
    this.background = const Color(0xFF1F2321),
    this.title = const Color(0xFFF5F7F6),
    this.label = const Color(0xFF9AA3A0),
    this.value = const Color(0xFFF5F7F6),
    this.success = const Color(0xFF4ADE80),
    this.warning = const Color(0xFFFBBF24),
    this.failure = const Color(0xFFF87171),
    this.idle = const Color(0xFF5A625F),
    this.radius = 16,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 20),
    this.rowGap = 16,
  });

  final Color background;
  final Color title;
  final Color label;
  final Color value;
  final Color success;
  final Color warning;
  final Color failure;
  final Color idle;
  final double radius;
  final EdgeInsets padding;
  final double rowGap;

  Color colorFor(DiagStatus status) => switch (status) {
    DiagStatus.success => success,
    DiagStatus.warning => warning,
    DiagStatus.failed => failure,
    DiagStatus.running => label,
    DiagStatus.pending || DiagStatus.skipped => idle,
  };
}

class NetworkDiagnosticPanel extends StatefulWidget {
  const NetworkDiagnosticPanel({
    super.key,
    required this.service,
    this.title = 'Đo lường chi tiết',
    this.autoStart = true,
    this.showRetryButton = true,
    this.theme = const DiagTheme(),
    this.onCompleted,
  });

  final NetworkDiagnosticService service;
  final String title;
  final bool autoStart;
  final bool showRetryButton;
  final DiagTheme theme;

  /// Gọi khi chạy xong — tiện để log hoặc gửi report lên server.
  final ValueChanged<List<DiagStep>>? onCompleted;

  @override
  State<NetworkDiagnosticPanel> createState() => _NetworkDiagnosticPanelState();
}

class _NetworkDiagnosticPanelState extends State<NetworkDiagnosticPanel> {
  late List<DiagStep> _steps = widget.service.buildInitialSteps();
  StreamSubscription<List<DiagStep>>? _sub;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      // Chạy sau frame đầu để panel hiện skeleton trước, không chớp.
      WidgetsBinding.instance.addPostFrameCallback((_) => start());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.service.cancel();
    super.dispose();
  }

  /// Bắt đầu (hoặc chạy lại) toàn bộ phép đo.
  void start() {
    _sub?.cancel();
    widget.service.cancel();

    setState(() {
      _steps = widget.service.buildInitialSteps();
      _running = true;
    });

    _sub = widget.service.run().listen(
      (snapshot) {
        if (!mounted) return;
        setState(() => _steps = snapshot);
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _running = false);
        widget.onCompleted?.call(_steps);
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() => _running = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;

    return Container(
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(t.radius),
      ),
      padding: t.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: t.title,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
              if (widget.showRetryButton)
                _RetryButton(
                  running: _running,
                  color: t.label,
                  disabledColor: t.idle,
                  onTap: start,
                ),
            ],
          ),
          SizedBox(height: t.rowGap + 2),
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0) SizedBox(height: t.rowGap),
            _DiagRow(step: _steps[i], theme: t),
          ],
        ],
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({required this.step, required this.theme});

  final DiagStep step;
  final DiagTheme theme;

  @override
  Widget build(BuildContext context) {
    final dim = step.status == DiagStatus.pending;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _StatusIcon(status: step.status, theme: theme),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: dim ? theme.idle : theme.label,
                  fontSize: 16.5,
                  height: 1.25,
                ),
              ),
              if (step.detail != null) ...[
                const SizedBox(height: 2),
                Text(
                  step.detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.idle,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          flex: 6,
          child: Text(
            step.value ??
                (step.status == DiagStatus.running ? 'Đang đo…' : '—'),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: switch (step.status) {
                DiagStatus.failed => theme.failure,
                DiagStatus.warning => theme.warning,
                DiagStatus.pending || DiagStatus.skipped => theme.idle,
                _ => theme.value,
              },
              fontSize: 16.5,
              height: 1.25,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.theme});

  final DiagStatus status;
  final DiagTheme theme;

  @override
  Widget build(BuildContext context) {
    const size = 18.0;

    if (status == DiagStatus.running) {
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(theme.label),
        ),
      );
    }

    final icon = switch (status) {
      DiagStatus.success => Icons.check_circle,
      DiagStatus.warning => Icons.error,
      DiagStatus.failed => Icons.cancel,
      DiagStatus.skipped => Icons.remove_circle_outline,
      _ => Icons.circle_outlined,
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Icon(
        icon,
        key: ValueKey(status),
        size: size,
        color: theme.colorFor(status),
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({
    required this.running,
    required this.color,
    required this.disabledColor,
    required this.onTap,
  });

  final bool running;
  final Color color;
  final Color disabledColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: running ? null : onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(
        Icons.refresh,
        size: 20,
        color: running ? disabledColor : color,
      ),
      tooltip: 'Đo lại',
    );
  }
}
