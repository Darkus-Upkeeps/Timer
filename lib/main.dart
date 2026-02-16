import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
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
    final pages = const [TimersScreen(), ReportsScreen()];
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
  final bool isActive;

  WorkTimer({
    required this.id,
    required this.name,
    required this.product,
    required this.isActive,
  });

  factory WorkTimer.fromMap(Map<String, Object?> m) => WorkTimer(
        id: m['id'] as int,
        name: m['name'] as String,
        product: m['product'] as String,
        isActive: (m['is_active'] as int) == 1,
      );
}

class Segment {
  final int timerId;
  final DateTime startAt;
  final DateTime? endAt;

  Segment({required this.timerId, required this.startAt, this.endAt});

  factory Segment.fromMap(Map<String, Object?> m) => Segment(
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE timers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            product TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0
          );
        ''');
        await db.execute('''
          CREATE TABLE segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timer_id INTEGER NOT NULL,
            start_at_ms INTEGER NOT NULL,
            end_at_ms INTEGER,
            FOREIGN KEY(timer_id) REFERENCES timers(id) ON DELETE CASCADE
          );
        ''');
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
      'is_active': 0,
    });
  }

  static Future<void> deleteTimer(int id) async {
    final db = await database;
    await db.delete('segments', where: 'timer_id = ?', whereArgs: [id]);
    await db.delete('timers', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> startTimer(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('timers', {'is_active': 1}, where: 'id = ?', whereArgs: [timerId]);
    await db.insert('segments', {
      'timer_id': timerId,
      'start_at_ms': now,
      'end_at_ms': null,
    });
  }

  static Future<void> pauseTimer(int timerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.update('timers', {'is_active': 0}, where: 'id = ?', whereArgs: [timerId]);

    final openSeg = await db.query(
      'segments',
      where: 'timer_id = ? AND end_at_ms IS NULL',
      whereArgs: [timerId],
      orderBy: 'start_at_ms DESC',
      limit: 1,
    );

    if (openSeg.isNotEmpty) {
      await db.update(
        'segments',
        {'end_at_ms': now},
        where: 'id = ?',
        whereArgs: [openSeg.first['id']],
      );
    }
  }

  static Future<List<Segment>> getSegmentsForTimer(int timerId) async {
    final db = await database;
    final rows = await db.query(
      'segments',
      where: 'timer_id = ?',
      whereArgs: [timerId],
      orderBy: 'start_at_ms ASC',
    );
    return rows.map(Segment.fromMap).toList();
  }
}

Duration overlapDuration({
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required DateTime segStart,
  required DateTime segEnd,
}) {
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

class TimerStats {
  final Duration today;
  final Duration total;

  const TimerStats({required this.today, required this.total});
}

Future<TimerStats> computeStats(WorkTimer timer) async {
  final segs = await DB.getSegmentsForTimer(timer.id);
  final now = DateTime.now();
  final dayStart = DateTime(now.year, now.month, now.day);
  Duration today = Duration.zero;
  Duration total = Duration.zero;

  for (final s in segs) {
    final end = s.endAt ?? now;
    if (!end.isAfter(s.startAt)) continue;
    total += end.difference(s.startAt);
    today += overlapDuration(
      rangeStart: dayStart,
      rangeEnd: now,
      segStart: s.startAt,
      segEnd: end,
    );
  }
  return TimerStats(today: today, total: total);
}

class TimersScreen extends StatefulWidget {
  const TimersScreen({super.key});

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

  Future<void> _addTimerDialog() async {
    final nameCtrl = TextEditingController();
    final productCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Timer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Task name')),
            TextField(controller: productCtrl, decoration: const InputDecoration(labelText: 'Product')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final n = nameCtrl.text.trim();
              final p = productCtrl.text.trim();
              if (n.isEmpty || p.isEmpty) return;
              await DB.createTimer(n, p);
              if (mounted) {
                Navigator.pop(context);
                setState(() {});
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(WorkTimer t) async {
    if (t.isActive) {
      await DB.pauseTimer(t.id);
    } else {
      await DB.startTimer(t.id);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Work Timers'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addTimerDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Timer'),
      ),
      body: FutureBuilder<List<WorkTimer>>(
        future: DB.getTimers(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final timers = snap.data!;
          if (timers.isEmpty) {
            return const Center(child: Text('No timers yet. Create your first one.'));
          }

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
                      final today = statsSnap.data?.today ?? Duration.zero;
                      final total = statsSnap.data?.total ?? Duration.zero;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                          Text('Product: ${t.product}'),
                          const SizedBox(height: 8),
                          Text('Partial (today): ${fmt(today)}'),
                          Text('Total (all-time): ${fmt(total)}'),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              FilledButton.icon(
                                onPressed: () => _toggle(t),
                                icon: Icon(t.isActive ? Icons.pause : Icons.play_arrow),
                                label: Text(t.isActive ? 'Pause' : 'Start'),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: () async {
                                  await DB.pauseTimer(t.id);
                                  await DB.deleteTimer(t.id);
                                  setState(() {});
                                },
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete'),
                              ),
                              const Spacer(),
                              if (t.isActive)
                                const Chip(
                                  label: Text('Running'),
                                  avatar: Icon(Icons.circle, size: 10, color: Colors.green),
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

  Future<Map<String, Duration>> _buildReport() async {
    final timers = await DB.getTimers();
    final (start, end) = _rangeNow();
    final map = <String, Duration>{};

    for (final t in timers) {
      final segs = await DB.getSegmentsForTimer(t.id);
      Duration sum = Duration.zero;
      for (final s in segs) {
        final segEnd = s.endAt ?? DateTime.now();
        sum += overlapDuration(
          rangeStart: start,
          rangeEnd: end,
          segStart: s.startAt,
          segEnd: segEnd,
        );
      }
      map[t.product] = (map[t.product] ?? Duration.zero) + sum;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
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
      body: FutureBuilder<Map<String, Duration>>(
        future: _buildReport(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          if (data.isEmpty) return const Center(child: Text('No data yet.'));
          final sorted = data.entries.toList()
            ..sort((a, b) => b.value.inSeconds.compareTo(a.value.inSeconds));

          return ListView(
            children: [
              for (final e in sorted)
                ListTile(
                  title: Text(e.key),
                  trailing: Text(fmt(e.value)),
                )
            ],
          );
        },
      ),
    );
  }
}
