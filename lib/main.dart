import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WorkTimerApp());
}

class WorkTimerApp extends StatelessWidget {
  const WorkTimerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WorkTimer',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const RootScreen(),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      TimersScreen(onOpenUpdates: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UpdatesScreen()))),
      const ReportsScreen(),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timer), label: 'Timers'),
          NavigationDestination(icon: Icon(Icons.analytics), label: 'Reports'),
        ],
      ),
    );
  }
}

class WorkTimer {
  final int id;
  final String name;
  final String product;
  final bool isTotalActive;
  final bool isPartialActive;
  final int partialAdjustSec;
  final int totalAdjustSec;
  final int createdAtMs;

  WorkTimer({
    required this.id,
    required this.name,
    required this.product,
    required this.isTotalActive,
    required this.isPartialActive,
    required this.partialAdjustSec,
    required this.totalAdjustSec,
    required this.createdAtMs,
  });

  factory WorkTimer.fromMap(Map<String, Object?> m) => WorkTimer(
        id: m['id'] as int,
        name: m['name'] as String,
        product: m['product'] as String,
        isTotalActive: (m['is_total_active'] as int? ?? 0) == 1,
        isPartialActive: (m['is_partial_active'] as int? ?? 0) == 1,
        partialAdjustSec: (m['partial_adjust_sec'] as int? ?? 0),
        totalAdjustSec: (m['total_adjust_sec'] as int? ?? 0),
        createdAtMs: (m['created_at_ms'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      );
}

class Segment {
  final int id;
  final int timerId;
  final DateTime startAt;
  final DateTime? endAt;

  Segment({required this.id, required this.timerId, required this.startAt, this.endAt});

  factory Segment.fromMap(Map<String, Object?> m) => Segment(
        id: m['id'] as int,
        timerId: m['timer_id'] as int,
        startAt: DateTime.fromMillisecondsSinceEpoch(m['start_at_ms'] as int),
        endAt: m['end_at_ms'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['end_at_ms'] as int),
      );
}

class DB {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'work_timer.db'),
      version: 4,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE timers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            product TEXT NOT NULL,
            is_total_active INTEGER NOT NULL DEFAULT 0,
            is_partial_active INTEGER NOT NULL DEFAULT 0,
            partial_adjust_sec INTEGER NOT NULL DEFAULT 0,
            total_adjust_sec INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE total_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            start_at_ms INTEGER NOT NULL,
            end_at_ms INTEGER,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE partial_segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            start_at_ms INTEGER NOT NULL,
            end_at_ms INTEGER,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          )
        ''');
      },
      onUpgrade: (db, oldVersion, _) async {
        await db.execute('ALTER TABLE timers ADD COLUMN is_total_active INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        await db.execute('ALTER TABLE timers ADD COLUMN is_partial_active INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        await db.execute('ALTER TABLE timers ADD COLUMN partial_adjust_sec INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        await db.execute('ALTER TABLE timers ADD COLUMN total_adjust_sec INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        await db.execute('ALTER TABLE timers ADD COLUMN created_at_ms INTEGER').catchError((_) {});

        await db.execute('''
          CREATE TABLE IF NOT EXISTS total_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            start_at_ms INTEGER NOT NULL,
            end_at_ms INTEGER,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS partial_segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            start_at_ms INTEGER NOT NULL,
            end_at_ms INTEGER,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          )
        ''');

        if (oldVersion < 3) {
          final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='time_entries'");
          if (tables.isNotEmpty) {
            final oldEntries = await db.query('time_entries');
            for (final e in oldEntries) {
              final start = DateTime.parse(e['started_at'] as String).millisecondsSinceEpoch;
              final endRaw = e['ended_at'] as String?;
              final end = endRaw == null ? null : DateTime.parse(endRaw).millisecondsSinceEpoch;
              await db.insert('total_sessions', {
                'timer_id': e['timer_id'],
                'start_at_ms': start,
                'end_at_ms': end,
              });
              await db.insert('partial_segments', {
                'timer_id': e['timer_id'],
                'start_at_ms': start,
                'end_at_ms': end,
              });
            }
          }
        }

        if (oldVersion < 4) {
          await db.rawUpdate('UPDATE timers SET created_at_ms = COALESCE(created_at_ms, strftime("%s","now") * 1000)');
          await db.rawUpdate('UPDATE timers SET partial_adjust_sec = COALESCE(partial_adjust_sec, 0)');
          await db.rawUpdate('UPDATE timers SET total_adjust_sec = COALESCE(total_adjust_sec, 0)');
        }
      },
    );
    return _db!;
  }

  static Future<List<WorkTimer>> getTimers() async {
    final db = await database;
    final rows = await db.query('timers', orderBy: 'id DESC');
    return rows.map(WorkTimer.fromMap).toList();
  }

  static Future<int> createTimer(String name, String product) async {
    final db = await database;
    return db.insert('timers', {
      'name': name.trim(),
      'product': product.trim(),
      'is_total_active': 0,
      'is_partial_active': 0,
      'partial_adjust_sec': 0,
      'total_adjust_sec': 0,
      'created_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> updateTimer(
    int id,
    String name,
    String product, {
    int? partialAdjustSec,
    int? totalAdjustSec,
    int? createdAtMs,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final values = <String, Object?>{'name': name.trim(), 'product': product.trim()};
      if (partialAdjustSec != null) values['partial_adjust_sec'] = partialAdjustSec;
      if (totalAdjustSec != null) values['total_adjust_sec'] = totalAdjustSec;

      if (createdAtMs != null) {
        final firstSession = await txn.rawQuery(
          'SELECT MIN(start_at_ms) AS first_start FROM total_sessions WHERE timer_id = ?',
          [id],
        );
        final firstStart = (firstSession.first['first_start'] as int?) ?? createdAtMs;
        final delta = createdAtMs - firstStart;

        if (delta != 0) {
          await txn.rawUpdate('UPDATE total_sessions SET start_at_ms = start_at_ms + ?, end_at_ms = CASE WHEN end_at_ms IS NULL THEN NULL ELSE end_at_ms + ? END WHERE timer_id = ?', [delta, delta, id]);
          await txn.rawUpdate('UPDATE partial_segments SET start_at_ms = start_at_ms + ?, end_at_ms = CASE WHEN end_at_ms IS NULL THEN NULL ELSE end_at_ms + ? END WHERE timer_id = ?', [delta, delta, id]);
        }

        values['created_at_ms'] = createdAtMs;
      }

      await txn.update('timers', values, where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> deleteTimer(int id) async {
    final db = await database;
    await db.delete('total_sessions', where: 'timer_id = ?', whereArgs: [id]);
    await db.delete('partial_segments', where: 'timer_id = ?', whereArgs: [id]);
    await db.delete('timers', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> start(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update('timers', {'is_total_active': 1, 'is_partial_active': 1}, where: 'id = ?', whereArgs: [timerId]);
    await db.insert('total_sessions', {'timer_id': timerId, 'start_at_ms': now, 'end_at_ms': null});
    await db.insert('partial_segments', {'timer_id': timerId, 'start_at_ms': now, 'end_at_ms': null});
  }

  static Future<void> pausePartial(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update('timers', {'is_partial_active': 0}, where: 'id = ?', whereArgs: [timerId]);
    final openSeg = await db.query('partial_segments', where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId], orderBy: 'start_at_ms DESC', limit: 1);
    if (openSeg.isNotEmpty) {
      await db.update('partial_segments', {'end_at_ms': now}, where: 'id = ?', whereArgs: [openSeg.first['id']]);
    }
  }

  static Future<void> resumePartial(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update('timers', {'is_partial_active': 1}, where: 'id = ?', whereArgs: [timerId]);
    await db.insert('partial_segments', {'timer_id': timerId, 'start_at_ms': now, 'end_at_ms': null});
  }

  static Future<void> stop(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update('timers', {'is_total_active': 0, 'is_partial_active': 0}, where: 'id = ?', whereArgs: [timerId]);

    final openPartial = await db.query('partial_segments', where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId], orderBy: 'start_at_ms DESC', limit: 1);
    if (openPartial.isNotEmpty) {
      await db.update('partial_segments', {'end_at_ms': now}, where: 'id = ?', whereArgs: [openPartial.first['id']]);
    }

    final openTotal = await db.query('total_sessions', where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId], orderBy: 'start_at_ms DESC', limit: 1);
    if (openTotal.isNotEmpty) {
      await db.update('total_sessions', {'end_at_ms': now}, where: 'id = ?', whereArgs: [openTotal.first['id']]);
    }
  }

  static Future<List<Segment>> getPartialSegmentsForTimer(int timerId) async {
    final db = await database;
    final rows = await db.query('partial_segments', where: 'timer_id = ?', whereArgs: [timerId], orderBy: 'start_at_ms ASC');
    return rows.map(Segment.fromMap).toList();
  }

  static Future<List<Segment>> getTotalSessionsForTimer(int timerId) async {
    final db = await database;
    final rows = await db.query('total_sessions', where: 'timer_id = ?', whereArgs: [timerId], orderBy: 'start_at_ms ASC');
    return rows.map(Segment.fromMap).toList();
  }

  static Future<void> deleteReportEntry({
    required int timerId,
    required int totalSessionId,
    required int sessionStartMs,
    required int sessionEndMs,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('total_sessions', where: 'id = ?', whereArgs: [totalSessionId]);
      await txn.rawDelete(
        '''
        DELETE FROM partial_segments
        WHERE timer_id = ?
          AND start_at_ms >= ?
          AND COALESCE(end_at_ms, start_at_ms) <= ?
        ''',
        [timerId, sessionStartMs, sessionEndMs],
      );
    });
  }
}

Duration overlapDuration({required DateTime rangeStart, required DateTime rangeEnd, required DateTime segStart, required DateTime segEnd}) {
  final start = segStart.isAfter(rangeStart) ? segStart : rangeStart;
  final end = segEnd.isBefore(rangeEnd) ? segEnd : rangeEnd;
  if (!end.isAfter(start)) return Duration.zero;
  return end.difference(start);
}

String fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String fmtDateTime(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final mi = dt.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}

int parseDurationInputToSeconds(String input) {
  final v = input.trim();
  if (v.isEmpty) return 0;
  if (v.contains(':')) {
    final parts = v.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
  }
  return int.tryParse(v) ?? 0;
}

class TimerStats {
  final Duration partialToday;
  final Duration totalAllTime;

  const TimerStats({required this.partialToday, required this.totalAllTime});
}

Future<TimerStats> computeStats(WorkTimer timer) async {
  final partialSegs = await DB.getPartialSegmentsForTimer(timer.id);
  final totalSegs = await DB.getTotalSessionsForTimer(timer.id);
  final now = DateTime.now();
  final dayStart = DateTime(now.year, now.month, now.day);

  Duration partialToday = Duration.zero;
  Duration totalAllTime = Duration.zero;

  for (final s in partialSegs) {
    final end = s.endAt ?? now;
    if (!end.isAfter(s.startAt)) continue;
    partialToday += overlapDuration(rangeStart: dayStart, rangeEnd: now, segStart: s.startAt, segEnd: end);
  }
  for (final s in totalSegs) {
    final end = s.endAt ?? now;
    if (!end.isAfter(s.startAt)) continue;
    totalAllTime += end.difference(s.startAt);
  }

  partialToday += Duration(seconds: timer.partialAdjustSec);
  totalAllTime += Duration(seconds: timer.totalAdjustSec);
  if (partialToday.isNegative) partialToday = Duration.zero;
  if (totalAllTime.isNegative) totalAllTime = Duration.zero;

  return TimerStats(partialToday: partialToday, totalAllTime: totalAllTime);
}

class TimersScreen extends StatefulWidget {
  const TimersScreen({super.key, required this.onOpenUpdates});
  final VoidCallback onOpenUpdates;

  @override
  State<TimersScreen> createState() => _TimersScreenState();
}

class _TimersScreenState extends State<TimersScreen> {
  late Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _timerDialog({WorkTimer? timer}) async {
    final nameCtrl = TextEditingController(text: timer?.name ?? '');
    final productCtrl = TextEditingController(text: timer?.product ?? '');
    final partialCtrl = TextEditingController(text: timer == null ? '0' : fmt(Duration(seconds: timer.partialAdjustSec)));
    final totalCtrl = TextEditingController(text: timer == null ? '0' : fmt(Duration(seconds: timer.totalAdjustSec)));
    DateTime selectedCreated = timer == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(timer.createdAtMs);

    Future<void> pickDate(StateSetter setLocal) async {
      final picked = await showDatePicker(
        context: context,
        initialDate: selectedCreated,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (picked != null) {
        selectedCreated = DateTime(
          picked.year,
          picked.month,
          picked.day,
          selectedCreated.hour,
          selectedCreated.minute,
        );
        setLocal(() {});
      }
    }

    Future<void> pickTime(StateSetter setLocal) async {
      final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(selectedCreated),
      );
      if (picked != null) {
        selectedCreated = DateTime(
          selectedCreated.year,
          selectedCreated.month,
          selectedCreated.day,
          picked.hour,
          picked.minute,
        );
        setLocal(() {});
      }
    }

    Future<void> pickCorrection(TextEditingController ctrl) async {
      final picked = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 0, minute: 0),
      );
      if (picked != null) {
        ctrl.text = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}:00';
      }
    }

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(timer == null ? 'New Timer' : 'Edit Timer'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Task name')),
                TextField(controller: productCtrl, decoration: const InputDecoration(labelText: 'Product')),
                if (timer != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: Text('Created: ${fmtDateTime(selectedCreated)}')),
                      IconButton(onPressed: () => pickDate(setLocal), icon: const Icon(Icons.calendar_today)),
                      IconButton(onPressed: () => pickTime(setLocal), icon: const Icon(Icons.schedule)),
                    ],
                  ),
                  TextField(
                    controller: partialCtrl,
                    decoration: InputDecoration(
                      labelText: 'Partial correction (HH:MM:SS or seconds)',
                      suffixIcon: IconButton(onPressed: () => pickCorrection(partialCtrl), icon: const Icon(Icons.schedule)),
                    ),
                  ),
                  TextField(
                    controller: totalCtrl,
                    decoration: InputDecoration(
                      labelText: 'Total correction (HH:MM:SS or seconds)',
                      suffixIcon: IconButton(onPressed: () => pickCorrection(totalCtrl), icon: const Icon(Icons.schedule)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final n = nameCtrl.text.trim();
                final p = productCtrl.text.trim();
                if (n.isEmpty || p.isEmpty) return;
                if (timer == null) {
                  await DB.createTimer(n, p);
                } else {
                  await DB.updateTimer(
                    timer.id,
                    n,
                    p,
                    partialAdjustSec: parseDurationInputToSeconds(partialCtrl.text),
                    totalAdjustSec: parseDurationInputToSeconds(totalCtrl.text),
                    createdAtMs: selectedCreated.millisecondsSinceEpoch,
                  );
                }
                if (mounted) {
                  Navigator.pop(ctx);
                  setState(() {});
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _primaryAction(WorkTimer t) async {
    if (!t.isTotalActive) {
      await DB.start(t.id);
    } else if (t.isPartialActive) {
      await DB.pausePartial(t.id);
    } else {
      await DB.resumePartial(t.id);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Work Timers'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'updates') widget.onOpenUpdates();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'updates', child: Text('App Updates'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _timerDialog(),
        icon: const Icon(Icons.add),
        label: const Text('New Timer'),
      ),
      body: FutureBuilder<List<WorkTimer>>(
        future: DB.getTimers(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final timers = snap.data!;
          if (timers.isEmpty) return const Center(child: Text('No timers yet. Create your first one.'));

          return ListView.builder(
            itemCount: timers.length,
            itemBuilder: (_, i) {
              final t = timers[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FutureBuilder<TimerStats>(
                    future: computeStats(t),
                    builder: (context, statsSnap) {
                      final partial = statsSnap.data?.partialToday ?? Duration.zero;
                      final total = statsSnap.data?.totalAllTime ?? Duration.zero;

                      final primaryLabel = !t.isTotalActive ? 'Start' : (t.isPartialActive ? 'Pause' : 'Resume');
                      final primaryIcon = !t.isTotalActive ? Icons.play_arrow : (t.isPartialActive ? Icons.pause : Icons.play_arrow);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                          Text('Product: ${t.product}'),
                          Text('Created: ${fmtDateTime(DateTime.fromMillisecondsSinceEpoch(t.createdAtMs))}'),
                          const SizedBox(height: 8),
                          Text('Partial (today): ${fmt(partial)}'),
                          Text('Total (all-time): ${fmt(total)}'),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(onPressed: () => _primaryAction(t), icon: Icon(primaryIcon), label: Text(primaryLabel)),
                              OutlinedButton.icon(
                                onPressed: t.isTotalActive
                                    ? () async {
                                        await DB.stop(t.id);
                                        setState(() {});
                                      }
                                    : null,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop'),
                              ),
                              OutlinedButton.icon(onPressed: () => _timerDialog(timer: t), icon: const Icon(Icons.edit), label: const Text('Edit')),
                              TextButton.icon(
                                onPressed: () async {
                                  await DB.stop(t.id);
                                  await DB.deleteTimer(t.id);
                                  setState(() {});
                                },
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete'),
                              ),
                              if (t.isTotalActive)
                                Chip(
                                  label: Text(t.isPartialActive ? 'Running' : 'Paused (partial)'),
                                  avatar: Icon(Icons.circle, size: 10, color: t.isPartialActive ? Colors.green : Colors.orange),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ReportLine {
  final WorkTimer timer;
  final int totalSessionId;
  final DateTime start;
  final DateTime end;
  final Duration partial;
  final Duration total;
  final int pauseMinutes;

  ReportLine({
    required this.timer,
    required this.totalSessionId,
    required this.start,
    required this.end,
    required this.partial,
    required this.total,
    required this.pauseMinutes,
  });

  ReportLine copyWith({
    DateTime? start,
    DateTime? end,
    Duration? partial,
    Duration? total,
    int? pauseMinutes,
  }) {
    return ReportLine(
      timer: timer,
      totalSessionId: totalSessionId,
      start: start ?? this.start,
      end: end ?? this.end,
      partial: partial ?? this.partial,
      total: total ?? this.total,
      pauseMinutes: pauseMinutes ?? this.pauseMinutes,
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String period = 'today';

  (DateTime, DateTime) _rangeNow() {
    final now = DateTime.now();
    if (period == 'today') {
      return (DateTime(now.year, now.month, now.day), now);
    } else if (period == 'week') {
      final weekday = now.weekday;
      final start = DateTime(now.year, now.month, now.day).subtract(Duration(days: weekday - 1));
      return (start, now);
    } else {
      final start = DateTime(now.year, now.month, 1);
      return (start, now);
    }
  }

  Future<List<ReportLine>> _buildReportLines() async {
    final timers = await DB.getTimers();
    final timerById = {for (final t in timers) t.id: t};
    final (rangeStart, rangeEnd) = _rangeNow();

    final lines = <ReportLine>[];
    for (final t in timers) {
      final totals = await DB.getTotalSessionsForTimer(t.id);
      final partials = await DB.getPartialSegmentsForTimer(t.id);

      for (final session in totals) {
        final rawEnd = session.endAt ?? DateTime.now();
        final sessionTotal = overlapDuration(
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          segStart: session.startAt,
          segEnd: rawEnd,
        );
        if (sessionTotal == Duration.zero) continue;

        Duration partialInSession = Duration.zero;
        for (final pseg in partials) {
          final pend = pseg.endAt ?? DateTime.now();
          partialInSession += overlapDuration(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            segStart: pseg.startAt.isAfter(session.startAt) ? pseg.startAt : session.startAt,
            segEnd: pend.isBefore(rawEnd) ? pend : rawEnd,
          );
        }
        if (partialInSession > sessionTotal) partialInSession = sessionTotal;

        final pause = (sessionTotal - partialInSession).inMinutes;
        final timer = timerById[session.timerId];
        if (timer == null) continue;

        lines.add(ReportLine(
          timer: timer,
          totalSessionId: session.id,
          start: session.startAt,
          end: rawEnd,
          partial: partialInSession,
          total: sessionTotal,
          pauseMinutes: pause,
        ));
      }
    }

    // Apply timer-level corrections so reports stay in sync with edit values.
    final byTimer = <int, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      byTimer.putIfAbsent(lines[i].timer.id, () => []).add(i);
    }

    for (final t in timers) {
      final idxs = byTimer[t.id] ?? const <int>[];
      if (idxs.isEmpty) continue;
      var line = lines[idxs.first];

      if (t.partialAdjustSec != 0) {
        var newPartial = line.partial + Duration(seconds: t.partialAdjustSec);
        if (newPartial.isNegative) newPartial = Duration.zero;
        final newPause = (line.total - newPartial).inMinutes < 0 ? 0 : (line.total - newPartial).inMinutes;
        line = line.copyWith(partial: newPartial, pauseMinutes: newPause);
      }

      if (t.totalAdjustSec != 0) {
        var newTotal = line.total + Duration(seconds: t.totalAdjustSec);
        if (newTotal.isNegative) newTotal = Duration.zero;
        final newPause = (newTotal - line.partial).inMinutes < 0 ? 0 : (newTotal - line.partial).inMinutes;
        line = line.copyWith(total: newTotal, pauseMinutes: newPause);
      }

      lines[idxs.first] = line;
    }

    lines.sort((a, b) => a.start.compareTo(b.start));
    return lines;
  }

  DateTime _weekStart(DateTime d) => DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  int _isoWeek(DateTime d) {
    final thursday = d.add(Duration(days: 4 - d.weekday));
    final firstJan = DateTime(thursday.year, 1, 1);
    return ((thursday.difference(firstJan).inDays) / 7).floor() + 1;
  }

  String _safeName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  String _pdfFileName(List<ReportLine> lines) {
    final date = DateTime.now();
    final ds = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final names = lines.map((e) => e.timer.name).toSet().toList();
    if (names.length == 1) return '${_safeName(names.first)}-$ds.pdf';
    return 'report-$ds.pdf';
  }

  Future<Uint8List> _buildPdfBytes(List<ReportLine> lines) async {
    final pdf = pw.Document();
    final (rangeStart, rangeEnd) = _rangeNow();
    final totalPartial = lines.fold<Duration>(Duration.zero, (a, b) => a + b.partial);

    final widgets = <pw.Widget>[
      pw.Text('Zeitanachweis', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 8),
      pw.Text('Zeitraum: ${fmtDateTime(rangeStart)} bis ${fmtDateTime(rangeEnd)}'),
      pw.SizedBox(height: 12),
    ];

    if (period == 'month') {
      final grouped = <DateTime, List<ReportLine>>{};
      for (final l in lines) {
        grouped.putIfAbsent(_weekStart(l.start), () => []).add(l);
      }
      final keys = grouped.keys.toList()..sort((a, b) => a.compareTo(b));

      for (final wk in keys) {
        final block = grouped[wk]!;
        final weekTotal = block.fold<Duration>(Duration.zero, (a, b) => a + b.partial);
        final kw = _isoWeek(wk);
        widgets.add(pw.Text('KW $kw • Woche ab ${fmtDateTime(wk).split(' ').first}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)));
        widgets.add(
          pw.Table.fromTextArray(
            headers: const ['Datum', 'Beginn', 'Ende', 'Pause (min)', 'Dauer', 'Timer', 'Produkt'],
            data: [
              for (final l in block)
                [
                  fmtDateTime(l.start).split(' ').first,
                  fmtDateTime(l.start).split(' ').last,
                  fmtDateTime(l.end).split(' ').last,
                  '${l.pauseMinutes}',
                  fmt(l.partial),
                  l.timer.name,
                  l.timer.product,
                ],
            ],
          ),
        );
        widgets.add(pw.SizedBox(height: 4));
        widgets.add(pw.Text('Wochensumme: ${fmt(weekTotal)}'));
        widgets.add(pw.SizedBox(height: 12));
      }
    } else {
      widgets.add(
        pw.Table.fromTextArray(
          headers: const ['Datum', 'Beginn', 'Ende', 'Pause (min)', 'Dauer', 'Timer', 'Produkt'],
          data: [
            for (final l in lines)
              [
                fmtDateTime(l.start).split(' ').first,
                fmtDateTime(l.start).split(' ').last,
                fmtDateTime(l.end).split(' ').last,
                '${l.pauseMinutes}',
                fmt(l.partial),
                l.timer.name,
                l.timer.product,
              ],
          ],
        ),
      );
      widgets.add(pw.SizedBox(height: 12));
    }

    widgets.add(pw.Text('Monatssumme / Gesamt: ${fmt(totalPartial)}'));
    widgets.add(pw.SizedBox(height: 24));
    widgets.add(
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Datum: ____________________'),
          pw.Text('Signatur: ____________________'),
        ],
      ),
    );

    pdf.addPage(pw.MultiPage(build: (_) => widgets));
    return pdf.save();
  }

  Future<void> _exportPdf(List<ReportLine> lines) async {
    final bytes = await _buildPdfBytes(lines);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: _pdfFileName(lines));
  }

  Future<void> _sharePdf(List<ReportLine> lines) async {
    final bytes = await _buildPdfBytes(lines);
    await Printing.sharePdf(bytes: bytes, filename: _pdfFileName(lines));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports (Partial Time)'),
        actions: [
          DropdownButton<String>(
            value: period,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'today', child: Text('Today')),
              DropdownMenuItem(value: 'week', child: Text('Week')),
              DropdownMenuItem(value: 'month', child: Text('Month')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => period = v);
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: FutureBuilder<List<ReportLine>>(
        future: _buildReportLines(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final lines = snap.data!;
          if (lines.isEmpty) return const Center(child: Text('No data yet.'));
          final totalPartial = lines.fold<Duration>(Duration.zero, (a, b) => a + b.partial);

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total partial time'),
                      Text(fmt(totalPartial)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _exportPdf(lines),
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('Print PDF'),
                          ),
                          FilledButton.icon(
                            onPressed: () => _sharePdf(lines),
                            icon: const Icon(Icons.share),
                            label: const Text('Share'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              for (final l in lines)
                Card(
                  child: ListTile(
                    title: Text('${l.timer.name} • ${l.timer.product}'),
                    subtitle: Text('${fmtDateTime(l.start)} → ${fmtDateTime(l.end)}\nPause: ${l.pauseMinutes} min'),
                    trailing: Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(fmt(l.partial)),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete report entry',
                          onPressed: () async {
                            await DB.deleteReportEntry(
                              timerId: l.timer.id,
                              totalSessionId: l.totalSessionId,
                              sessionStartMs: l.start.millisecondsSinceEpoch,
                              sessionEndMs: l.end.millisecondsSinceEpoch,
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'github_pat';
  static const _owner = 'Darkus-Upkeeps';
  static const _repo = 'Timer';

  final _tokenController = TextEditingController();
  bool _hideToken = true;
  bool _busy = false;
  String _status = 'Idle';
  int _localVersionCode = 0;
  UpdateManifest? _manifest;

  @override
  void initState() {
    super.initState();
    _loadToken();
    _loadLocalVersion();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    _tokenController.text = await _storage.read(key: _tokenKey) ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _loadLocalVersion() async {
    final info = await PackageInfo.fromPlatform();
    _localVersionCode = int.tryParse(info.buildNumber) ?? 0;
    if (mounted) setState(() {});
  }

  Future<void> _saveToken() async {
    await _storage.write(key: _tokenKey, value: _tokenController.text.trim());
    if (mounted) setState(() => _status = 'Token saved.');
  }

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<void> _check() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _status = 'Enter token first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Checking latest-stable...';
    });

    try {
      final url = Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/tags/latest-stable');
      final res = await http.get(url, headers: _headers(token));
      if (res.statusCode != 200) throw Exception('Release fetch failed (${res.statusCode})');

      final release = jsonDecode(res.body) as Map<String, dynamic>;
      final assets = (release['assets'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
      final apk = assets.firstWhere((a) => (a['name'] as String? ?? '').endsWith('.apk'), orElse: () => <String, dynamic>{});
      if (apk.isEmpty) throw Exception('No APK asset in release');

      final bodyRaw = (release['body'] as String? ?? '{}').trim();
      final meta = jsonDecode(bodyRaw) as Map<String, dynamic>;
      _manifest = UpdateManifest(
        versionCode: (meta['versionCode'] as num?)?.toInt() ?? 0,
        versionName: (meta['versionName'] as String?) ?? '0.0.0',
        sha256: (meta['sha256'] as String?) ?? '',
        notes: (meta['notes'] as String?) ?? '',
        apkApiUrl: (apk['url'] as String?) ?? '',
        apkFileName: (apk['name'] as String?) ?? 'work-timer.apk',
      );

      setState(() {
        _status = _manifest!.versionCode > _localVersionCode
            ? 'Update available: ${_manifest!.versionName} (${_manifest!.versionCode})'
            : 'Already up to date (${_manifest!.versionName})';
      });
    } catch (e) {
      setState(() => _status = 'Update check failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final token = _tokenController.text.trim();
    final m = _manifest;
    if (token.isEmpty || m == null) {
      setState(() => _status = 'Run Check Update first.');
      return;
    }
    if (m.versionCode <= _localVersionCode) {
      setState(() => _status = 'No newer version to install.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Downloading APK...';
    });

    try {
      Directory dir;
      if (Platform.isAndroid) {
        dir = Directory('/storage/emulated/0/Download');
        if (!await dir.exists()) {
          dir = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
        }
      } else {
        dir = await getApplicationDocumentsDirectory();
      }

      final out = File('${dir.path}/${m.apkFileName}');
      final req = await HttpClient().getUrl(Uri.parse(m.apkApiUrl));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');

      final resp = await req.close();
      if (resp.statusCode != 200) throw Exception('Download failed (${resp.statusCode})');
      await resp.pipe(out.openWrite());

      final digest = sha256.convert(await out.readAsBytes()).toString();
      if (m.sha256.isNotEmpty && digest.toLowerCase() != m.sha256.toLowerCase()) {
        await out.delete();
        throw Exception('Checksum mismatch');
      }

      setState(() => _status = 'Downloaded: ${out.path}');
      final result = await OpenFilex.open(out.path, type: 'application/vnd.android.package-archive');
      setState(() => _status = 'Installer: ${result.type} ${result.message}. If blocked, allow "Install unknown apps" for Work Timer.');
    } catch (e) {
      setState(() => _status = 'Install failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUpdate = _manifest != null && _manifest!.versionCode > _localVersionCode;
    return Scaffold(
      appBar: AppBar(title: const Text('App Updates')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: _busy ? null : _check, child: const Text('Check Update')),
              OutlinedButton(onPressed: _busy || !hasUpdate ? null : _install, child: const Text('Install Latest')),
            ],
          ),
          const SizedBox(height: 10),
          Text(_status),
          if (_manifest != null) ...[
            const SizedBox(height: 8),
            Text('Remote: ${_manifest!.versionName} (${_manifest!.versionCode})'),
            Text('Notes: ${_manifest!.notes}'),
          ],
        ],
      ),
    );
  }
}

class UpdateManifest {
  final int versionCode;
  final String versionName;
  final String sha256;
  final String notes;
  final String apkApiUrl;
  final String apkFileName;

  UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.sha256,
    required this.notes,
    required this.apkApiUrl,
    required this.apkFileName,
  });
}
