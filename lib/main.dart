import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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

class WorkTimer {
  WorkTimer({required this.id, required this.name, required this.product});

  final int id;
  final String name;
  final String product;

  factory WorkTimer.fromMap(Map<String, Object?> map) => WorkTimer(
        id: map['id'] as int,
        name: map['name'] as String,
        product: (map['product'] as String?) ?? '',
      );
}

class TimerRow {
  TimerRow({
    required this.timer,
    required this.totalSeconds,
    required this.isRunning,
    required this.activeStartedAt,
  });

  final WorkTimer timer;
  final int totalSeconds;
  final bool isRunning;
  final DateTime? activeStartedAt;

  Duration liveDuration(DateTime now) {
    var secs = totalSeconds;
    if (activeStartedAt != null) {
      secs += now.difference(activeStartedAt!).inSeconds;
    }
    return Duration(seconds: secs);
  }
}

class ReportRow {
  ReportRow({required this.name, required this.product, required this.seconds});

  final String name;
  final String product;
  final int seconds;
}

class Db {
  static Database? _db;

  static Future<Database> instance() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'work_timer.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE timers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            product TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE time_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          )
        ''');
      },
    );
    return _db!;
  }
}

class TimerRepo {
  Future<List<TimerRow>> loadRows() async {
    final db = await Db.instance();
    final rows = await db.rawQuery('''
      SELECT
        t.id,
        t.name,
        t.product,
        COALESCE(SUM(CASE
          WHEN e.ended_at IS NOT NULL THEN (strftime('%s', e.ended_at) - strftime('%s', e.started_at))
          ELSE 0
        END), 0) AS total_seconds,
        MAX(CASE WHEN e.ended_at IS NULL THEN e.started_at END) AS active_started_at
      FROM timers t
      LEFT JOIN time_entries e ON e.timer_id = t.id
      GROUP BY t.id, t.name, t.product
      ORDER BY t.id DESC
    ''');

    return rows.map((r) {
      final timer = WorkTimer.fromMap(r);
      final activeRaw = r['active_started_at'] as String?;
      return TimerRow(
        timer: timer,
        totalSeconds: (r['total_seconds'] as num?)?.toInt() ?? 0,
        isRunning: activeRaw != null,
        activeStartedAt: activeRaw == null ? null : DateTime.tryParse(activeRaw)?.toLocal(),
      );
    }).toList();
  }

  Future<void> createTimer(String name, String product) async {
    final db = await Db.instance();
    await db.insert('timers', {'name': name.trim(), 'product': product.trim()});
  }

  Future<void> updateTimer(int id, String name, String product) async {
    final db = await Db.instance();
    await db.update(
      'timers',
      {'name': name.trim(), 'product': product.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteTimer(int id) async {
    final db = await Db.instance();
    await db.delete('time_entries', where: 'timer_id = ?', whereArgs: [id]);
    await db.delete('timers', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> startTimer(int timerId) async {
    final db = await Db.instance();
    final already = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM time_entries WHERE timer_id = ? AND ended_at IS NULL',
      [timerId],
    ));
    if ((already ?? 0) > 0) return;

    await db.insert('time_entries', {
      'timer_id': timerId,
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'ended_at': null,
    });
  }

  Future<void> stopTimer(int timerId) async {
    final db = await Db.instance();
    await db.rawUpdate(
      '''
      UPDATE time_entries
      SET ended_at = ?
      WHERE id = (
        SELECT id
        FROM time_entries
        WHERE timer_id = ? AND ended_at IS NULL
        ORDER BY id DESC
        LIMIT 1
      )
      ''',
      [DateTime.now().toUtc().toIso8601String(), timerId],
    );
  }

  Future<List<ReportRow>> reportRows({DateTime? from}) async {
    final db = await Db.instance();
    final args = <Object?>[];
    final whereFrom = from == null ? '' : 'AND e.started_at >= ?';
    if (from != null) args.add(from.toUtc().toIso8601String());

    final rows = await db.rawQuery('''
      SELECT t.name, t.product,
      COALESCE(SUM(CASE
        WHEN e.ended_at IS NOT NULL THEN (strftime('%s', e.ended_at) - strftime('%s', e.started_at))
        ELSE (strftime('%s', 'now') - strftime('%s', e.started_at))
      END), 0) AS seconds
      FROM timers t
      LEFT JOIN time_entries e ON e.timer_id = t.id $whereFrom
      GROUP BY t.id, t.name, t.product
      ORDER BY seconds DESC, t.name ASC
    ''', args);

    return rows
        .map(
          (r) => ReportRow(
            name: (r['name'] as String?) ?? '-',
            product: (r['product'] as String?) ?? '',
            seconds: (r['seconds'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
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

  final repo = TimerRepo();
  final _tokenController = TextEditingController();

  Timer? _ticker;
  List<TimerRow> _rows = [];
  bool _loading = true;

  bool _updateBusy = false;
  String _updateStatus = 'Idle';
  UpdateManifest? _manifest;
  int _localVersionCode = 0;
  bool _hideToken = true;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    _loadLocalVersion();
    _loadToken();
    _refresh();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final rows = await repo.loadRows();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _loadToken() async {
    final token = await _storage.read(key: _tokenKey) ?? '';
    if (!mounted) return;
    setState(() => _tokenController.text = token);
  }

  Future<void> _saveToken() async {
    await _storage.write(key: _tokenKey, value: _tokenController.text.trim());
    if (!mounted) return;
    setState(() => _updateStatus = 'GitHub token saved securely.');
  }

  Future<void> _loadLocalVersion() async {
    final info = await PackageInfo.fromPlatform();
    final vc = int.tryParse(info.buildNumber) ?? 0;
    if (!mounted) return;
    setState(() => _localVersionCode = vc);
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
      _updateStatus = 'Checking release...';
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
        channel: (meta['channel'] as String?) ?? 'stable',
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
      setState(() => _updateStatus = 'Update check failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => _updateBusy = false);
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
        throw Exception('Checksum mismatch');
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
      setState(() => _updateBusy = false);
    }
  }

  Future<void> _showTimerDialog({WorkTimer? timer}) async {
    final name = TextEditingController(text: timer?.name ?? '');
    final product = TextEditingController(text: timer?.product ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(timer == null ? 'Add Timer' : 'Edit Timer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Timer Name')),
            TextField(controller: product, decoration: const InputDecoration(labelText: 'Product')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              if (timer == null) {
                await repo.createTimer(name.text, product.text);
              } else {
                await repo.updateTimer(timer.id, name.text, product.text);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              await _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReports() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReportPage(repo: repo, fmt: _fmt)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hasUpdate = _manifest != null && _manifest!.versionCode > _localVersionCode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Work Timer'),
        actions: [
          IconButton(onPressed: _openReports, icon: const Icon(Icons.assessment), tooltip: 'Reports'),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTimerDialog(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_rows.isEmpty)
                  const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No timers yet. Tap + to create one.'))),
                ..._rows.map(
                  (row) => Card(
                    child: ListTile(
                      title: Text(row.timer.name),
                      subtitle: Text('${row.timer.product}\n${_fmt(row.liveDuration(now))}'),
                      isThreeLine: true,
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            icon: Icon(row.isRunning ? Icons.stop : Icons.play_arrow),
                            onPressed: () async {
                              if (row.isRunning) {
                                await repo.stopTimer(row.timer.id);
                              } else {
                                await repo.startTimer(row.timer.id);
                              }
                              await _refresh();
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () => _showTimerDialog(timer: row.timer),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () async {
                              await repo.deleteTimer(row.timer.id);
                              await _refresh();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
                        const SizedBox(height: 8),
                        const Text('Channel: Stable'),
                        const SizedBox(height: 10),
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
                const SizedBox(height: 80),
              ],
            ),
    );
  }
}

class ReportPage extends StatefulWidget {
  const ReportPage({super.key, required this.repo, required this.fmt});

  final TimerRepo repo;
  final String Function(Duration) fmt;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  String filter = '7d';
  bool loading = true;
  List<ReportRow> rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? get from {
    final now = DateTime.now();
    if (filter == 'today') return DateTime(now.year, now.month, now.day);
    if (filter == '7d') return now.subtract(const Duration(days: 7));
    if (filter == '30d') return now.subtract(const Duration(days: 30));
    return null;
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final r = await widget.repo.reportRows(from: from);
    if (!mounted) return;
    setState(() {
      rows = r;
      loading = false;
    });
  }

  String _composeReport() {
    final b = StringBuffer('Work Timer Report ($filter)\n');
    for (final r in rows) {
      b.writeln('- ${r.name} [${r.product}]: ${widget.fmt(Duration(seconds: r.seconds))}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (a, b) => a + b.seconds);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy report',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _composeReport()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied')));
            },
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(label: const Text('Today'), selected: filter == 'today', onSelected: (_) { setState(() => filter = 'today'); _load(); }),
                    ChoiceChip(label: const Text('7d'), selected: filter == '7d', onSelected: (_) { setState(() => filter = '7d'); _load(); }),
                    ChoiceChip(label: const Text('30d'), selected: filter == '30d', onSelected: (_) { setState(() => filter = '30d'); _load(); }),
                    ChoiceChip(label: const Text('All'), selected: filter == 'all', onSelected: (_) { setState(() => filter = 'all'); _load(); }),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: const Text('Total time'),
                    subtitle: Text(widget.fmt(Duration(seconds: total))),
                  ),
                ),
                ...rows.map((r) => Card(
                      child: ListTile(
                        title: Text(r.name),
                        subtitle: Text(r.product),
                        trailing: Text(widget.fmt(Duration(seconds: r.seconds))),
                      ),
                    )),
              ],
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
