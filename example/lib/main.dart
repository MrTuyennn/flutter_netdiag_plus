import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_netdiag_plus/flutter_netdiag_plus.dart';

void main() => runApp(const NetDiagApp());

class NetDiagApp extends StatelessWidget {
  const NetDiagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Đo lường mạng',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121513),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4ADE80),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _defaultHost = 'example.com';

  final _hostController = TextEditingController(text: _defaultHost);

  late NetworkDiagnosticService _service;

  String _host = _defaultHost;

  /// Đổi token = ép panel dựng lại từ đầu và tự chạy.
  int _runToken = 0;

  List<DiagStep> _lastSteps = const [];
  TracerouteResult? _trace;

  @override
  void initState() {
    super.initState();
    _service = _buildService(_defaultHost);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _service.cancel();
    super.dispose();
  }

  NetworkDiagnosticService _buildService(String host) {
    return NetworkDiagnosticService(
      host: host,
      hopResolver: (target) async {
        final traceroute = createTraceroute();
        if (!traceroute.isSupported) return null;

        final result = await traceroute.trace(target);
        if (result.hops.isEmpty) return null;

        if (mounted) setState(() => _trace = result);
        return result.hopCount;
      },
    );
  }

  void _measure() {
    final host = _hostController.text
        .trim()
        .replaceAll(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    if (host.isEmpty) return;

    FocusScope.of(context).unfocus();
    _service.cancel();

    setState(() {
      _host = host;
      _service = _buildService(host);
      _runToken++;
      _lastSteps = const [];
      _trace = null;
    });
  }

  Future<void> _copyReport() async {
    final json = const JsonEncoder.withIndent('  ').convert({
      'host': _host,
      'at': DateTime.now().toIso8601String(),
      'steps': [
        for (final s in _lastSteps)
          {
            'id': s.id,
            'label': s.label,
            'status': s.status.name,
            'value': s.value,
            'detail': s.detail,
            'ms': s.elapsed?.inMilliseconds,
          },
      ],
      if (_trace != null)
        'traceroute': {
          'reachedDestination': _trace!.reachedDestination,
          'hops': [
            for (final h in _trace!.hops)
              {'ttl': h.ttl, 'address': h.address, 'rttMs': h.rttMs},
          ],
        },
    });

    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã copy report vào clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đo lường mạng'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextField(
              controller: _hostController,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _measure(),
              decoration: InputDecoration(
                labelText: 'Host cần đo',
                hintText: 'vd: api.example.com',
                filled: true,
                fillColor: const Color(0xFF1F2321),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.play_arrow_rounded),
                  tooltip: 'Đo',
                  onPressed: _measure,
                ),
              ),
            ),
            const SizedBox(height: 16),
            NetworkDiagnosticPanel(
              key: ValueKey('$_host#$_runToken'),
              service: _service,
              onCompleted: (steps) => setState(() => _lastSteps = steps),
            ),
            if (_trace != null) ...[
              const SizedBox(height: 16),
              _HopList(result: _trace!),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _lastSteps.isEmpty ? null : _copyReport,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy report (JSON)'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Ping dùng TCP connect tới port 443 — không cần quyền đặc biệt, '
              'không bị firewall drop như ICMP, và sát với độ trễ thật mà app cảm nhận.',
              style: TextStyle(
                color: Color(0xFF6B736F),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Danh sách chặng chi tiết, hiện sau khi traceroute xong.
class _HopList extends StatelessWidget {
  const _HopList({required this.result});

  final TracerouteResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2321),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Đường đi',
                  style: TextStyle(
                    color: Color(0xFFF5F7F6),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                result.reachedDestination
                    ? '${result.hopCount} chặng'
                    : '≥ ${result.hopCount} chặng',
                style: const TextStyle(color: Color(0xFF9AA3A0), fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final hop in result.hops)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${hop.ttl}',
                      style: const TextStyle(
                        color: Color(0xFF5A625F),
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      hop.address ?? '* * *',
                      style: TextStyle(
                        color: hop.isTimeout
                            ? const Color(0xFF5A625F)
                            : const Color(0xFFF5F7F6),
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (hop.rttMs != null)
                    Text(
                      '${hop.rttMs!.toStringAsFixed(1)}ms',
                      style: const TextStyle(
                        color: Color(0xFF9AA3A0),
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
          if (!result.reachedDestination) ...[
            const SizedBox(height: 10),
            const Text(
              'Chưa chạm đích trong giới hạn hop — số chặng ở trên là cận dưới.',
              style: TextStyle(
                color: Color(0xFF6B736F),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
