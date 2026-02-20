import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'github_pat';

  static const _owner = 'Darkus-Upkeeps';
  static const _repo = 'Timer';

  Timer? _ticker;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;

  final String _channel = 'stable';
  bool _updateBusy = false;
  String _updateStatus = 'Idle';
  UpdateManifest? _manifest;
  int _localVersionCode = 0;

  final _tokenController = TextEditingController();
  bool _hideToken = true;

  @override
  void initState() {
    super.initState();
    _loadLocalVersion();
    _loadToken();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    final token = await _storage.read(key: _tokenKey) ?? '';
    if (!mounted) return;
    setState(() {
      _tokenController.text = token;
    });
  }

  Future<void> _saveToken() async {
    await _storage.write(key: _tokenKey, value: _tokenController.text.trim());
    if (!mounted) return;
    setState(() {
      _updateStatus = 'GitHub token saved securely.';
    });
  }

  Future<void> _loadLocalVersion() async {
    final info = await PackageInfo.fromPlatform();
    final vc = int.tryParse(info.buildNumber) ?? 0;
    if (!mounted) return;
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

  String get _releaseTag => 'latest-stable';

  Map<String, String> _ghHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<void> _checkUpdate() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _updateStatus = 'Please enter GitHub token first.');
      return;
    }

    setState(() {
      _updateBusy = true;
      _updateStatus = 'Checking $_channel release...';
    });

    try {
      final url = Uri.parse(
        'https://api.github.com/repos/$_owner/$_repo/releases/tags/$_releaseTag',
      );
      final res = await http.get(url, headers: _ghHeaders(token));
      if (res.statusCode != 200) {
        throw Exception('Release fetch failed (${res.statusCode}): ${res.body}');
      }

      final release = jsonDecode(res.body) as Map<String, dynamic>;
      final assets = (release['assets'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      final apkAsset = assets.firstWhere(
        (a) => (a['name'] as String? ?? '').endsWith('.apk'),
        orElse: () => <String, dynamic>{},
      );
      if (apkAsset.isEmpty) throw Exception('No APK asset found in release.');

      final bodyRaw = (release['body'] as String? ?? '{}').trim();
      final meta = (jsonDecode(bodyRaw) as Map<String, dynamic>);

      final m = UpdateManifest(
        versionCode: (meta['versionCode'] as num?)?.toInt() ?? 0,
        versionName: (meta['versionName'] as String?) ?? '0.0.0',
        channel: (meta['channel'] as String?) ?? _channel,
        sha256: (meta['sha256'] as String?) ?? '',
        notes: (meta['notes'] as String?) ?? '',
        apkApiUrl: (apkAsset['url'] as String?) ?? '',
        apkFileName: (apkAsset['name'] as String?) ?? 'work-timer.apk',
      );

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
    final token = _tokenController.text.trim();
    final m = _manifest;
    if (token.isEmpty) {
      setState(() => _updateStatus = 'Missing GitHub token.');
      return;
    }
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
      final out = File('${dir.path}/${m.apkFileName}');

      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(m.apkApiUrl));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');

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
      final result = await OpenFilex.open(
        out.path,
        type: 'application/vnd.android.package-archive',
      );
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
        child: ListView(
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
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tokenController,
                      obscureText: _hideToken,
                      decoration: InputDecoration(
                        labelText: 'GitHub PAT (repo read)',
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _hideToken = !_hideToken),
                          icon: Icon(_hideToken ? Icons.visibility : Icons.visibility_off),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _saveToken, child: const Text('Save Token')),
                    const SizedBox(height: 12),
                    const Text('Channel: Stable'),
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
                      Text('Notes: ${_manifest!.notes}'),
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
    required this.sha256,
    required this.notes,
    required this.apkApiUrl,
    required this.apkFileName,
  });

  final int versionCode;
  final String versionName;
  final String channel;
  final String sha256;
  final String notes;
  final String apkApiUrl;
  final String apkFileName;
}
