import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const WorkTimerApp());
}

class WorkTimerApp extends StatelessWidget {
  const WorkTimerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Work Timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6A1B9A)),
        useMaterial3: true,
      ),
      home: const TimerHomePage(),
    );
  }
}

class TimerHomePage extends StatefulWidget {
  const TimerHomePage({super.key});

  @override
  State<TimerHomePage> createState() => _TimerHomePageState();
}

class _TimerHomePageState extends State<TimerHomePage> {
  Timer? _ticker;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;

  String _channel = 'stable';
  bool _updateBusy = false;
  String _updateStatus = 'Idle';
  UpdateManifest? _manifest;
  int _localVersionCode = 0;

  static const String _stableManifestUrl =
      'https://raw.githubusercontent.com/Darkus-Upkeeps/Timer/main/update/stable.json';
  static const String _betaManifestUrl =
      'https://raw.githubusercontent.com/Darkus-Upkeeps/Timer/main/update/beta.json';

  @override
  void initState() {
    super.initState();
    _loadLocalVersion();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadLocalVersion() async {
    final info = await PackageInfo.fromPlatform();
    final vc = int.tryParse(info.buildNumber) ?? 0;
    setState(() {
      _localVersionCode = vc;
    });
  }

  void _startTimer() {
    if (_ticker != null) return;
    _startedAt ??= DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(_startedAt!);
      });
    });
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _startedAt = null;
      _elapsed = Duration.zero;
    });
  }

  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get _manifestUrl =>
      _channel == 'stable' ? _stableManifestUrl : _betaManifestUrl;

  Future<void> _checkUpdate() async {
    setState(() {
      _updateBusy = true;
      _updateStatus = 'Checking $_channel channel...';
    });

    try {
      final res = await http.get(Uri.parse(_manifestUrl));
      if (res.statusCode != 200) {
        throw Exception('Manifest fetch failed (${res.statusCode})');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final m = UpdateManifest.fromJson(data);
      setState(() {
        _manifest = m;
        _updateStatus = m.versionCode > _localVersionCode
            ? 'Update available: ${m.versionName} (${m.versionCode})'
            : 'Already up to date (${m.versionName})';
      });
    } catch (e) {
      setState(() {
        _updateStatus = 'Update check failed: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _updateBusy = false;
      });
    }
  }

  Future<void> _installLatest() async {
    final m = _manifest;
    if (m == null) {
      setState(() => _updateStatus = 'Run update check first.');
      return;
    }
    if (m.versionCode <= _localVersionCode) {
      setState(() => _updateStatus = 'No newer version to install.');
      return;
    }

    setState(() {
      _updateBusy = true;
      _updateStatus = 'Downloading APK...';
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final out = File('${dir.path}/work-timer-${m.channel}-${m.versionCode}.apk');

      final req = await HttpClient().getUrl(Uri.parse(m.apkUrl));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('APK download failed (${resp.statusCode})');
      }
      await resp.pipe(out.openWrite());

      final digest = sha256.convert(await out.readAsBytes()).toString();
      if (m.sha256.isNotEmpty && digest.toLowerCase() != m.sha256.toLowerCase()) {
        await out.delete();
        throw Exception('Checksum mismatch (expected ${m.sha256}, got $digest)');
      }

      setState(() => _updateStatus = 'Launching installer...');
      final result = await OpenFilex.open(out.path, type: 'application/vnd.android.package-archive');
      setState(() => _updateStatus = 'Installer result: ${result.message}');
    } catch (e) {
      setState(() => _updateStatus = 'Install failed: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _updateBusy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUpdate = _manifest != null && _manifest!.versionCode > _localVersionCode;

    return Scaffold(
      appBar: AppBar(title: const Text('Work Timer')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(_fmt(_elapsed), style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(onPressed: _startTimer, child: const Text('Start')),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _stopTimer, child: const Text('Stop')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('App Updates', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text('Local versionCode: $_localVersionCode'),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'stable', label: Text('Stable')),
                        ButtonSegment(value: 'beta', label: Text('Beta')),
                      ],
                      selected: {_channel},
                      onSelectionChanged: (s) => setState(() => _channel = s.first),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _updateBusy ? null : _checkUpdate,
                          child: const Text('Check Update'),
                        ),
                        OutlinedButton(
                          onPressed: _updateBusy || !hasUpdate ? null : _installLatest,
                          child: const Text('Install Latest'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(_updateStatus),
                    if (_manifest != null) ...[
                      const SizedBox(height: 8),
                      Text('Remote: ${_manifest!.versionName} (${_manifest!.versionCode})'),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UpdateManifest {
  UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.channel,
    required this.apkUrl,
    required this.sha256,
    required this.notes,
  });

  final int versionCode;
  final String versionName;
  final String channel;
  final String apkUrl;
  final String sha256;
  final String notes;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    return UpdateManifest(
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: (json['versionName'] as String?) ?? '0.0.0',
      channel: (json['channel'] as String?) ?? 'stable',
      apkUrl: (json['apkUrl'] as String?) ?? '',
      sha256: (json['sha256'] as String?) ?? '',
      notes: (json['notes'] as String?) ?? '',
    );
  }
}
