import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'report_range.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifications.init();
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Notifications.requestPermission();
      await syncTimerNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      TimersScreen(onOpenUpdates: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UpdatesScreen()))),
      const ReportsScreen(),
      const DashboardScreen(),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timer), label: 'Timers'),
          NavigationDestination(icon: Icon(Icons.analytics), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
        ],
      ),
    );
  }
}

class Notifications {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings);
      _ready = true;
    } catch (_) {
      // Notifications unavailable (e.g. unsupported platform); app still works.
    }
  }

  static Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  static AndroidNotificationDetails _statusDetails({required bool running, int? chronometerBaseMs}) {
    return AndroidNotificationDetails(
      'timer_status',
      'Timer status',
      channelDescription: 'Shows active timers outside the app',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showWhen: running,
      when: chronometerBaseMs,
      usesChronometer: running,
      category: AndroidNotificationCategory.stopwatch,
      visibility: NotificationVisibility.public,
    );
  }

  static const AndroidNotificationDetails _eventDetails = AndroidNotificationDetails(
    'timer_events',
    'Timer events',
    channelDescription: 'Alerts when a timer auto-stops',
    importance: Importance.high,
    priority: Priority.high,
    visibility: NotificationVisibility.public,
  );

  static Future<void> showRunning(WorkTimer t, Duration partialElapsed, {DateTime? autoStopAt}) async {
    if (!_ready) return;
    final base = DateTime.now().millisecondsSinceEpoch - partialElapsed.inMilliseconds;
    final body = autoStopAt == null
        ? 'Running • ${t.product}'
        : 'Running • ${t.product} • auto-stop at ${fmtDateTime(autoStopAt)}';
    await _plugin.show(
      t.id,
      t.name,
      body,
      NotificationDetails(android: _statusDetails(running: true, chronometerBaseMs: base)),
    );
  }

  static Future<void> showPaused(WorkTimer t, Duration partialElapsed,
      {Duration? autoStopRemaining, String dayLabel = 'today'}) async {
    if (!_ready) return;
    final body = autoStopRemaining == null
        ? 'Paused • $dayLabel ${fmt(partialElapsed)}'
        : 'Paused • $dayLabel ${fmt(partialElapsed)} • ${fmt(autoStopRemaining)} left before auto-stop';
    await _plugin.show(
      t.id,
      t.name,
      body,
      NotificationDetails(android: _statusDetails(running: false)),
    );
  }

  static Future<void> showAutoStopped(WorkTimer t, DateTime stoppedAt) async {
    if (!_ready) return;
    // Cancel first so any pending scheduled notification with this id is cleared too.
    await _plugin.cancel(t.id);
    await _plugin.show(
      t.id,
      t.name,
      'Auto-stopped at ${fmtDateTime(stoppedAt)}',
      const NotificationDetails(android: _eventDetails),
    );
  }

  static Future<void> scheduleAutoStop(WorkTimer t, DateTime deadline) async {
    if (!_ready) return;
    if (!deadline.isAfter(DateTime.now())) return;
    try {
      await _plugin.zonedSchedule(
        t.id,
        t.name,
        'Auto-stopped at ${fmtDateTime(deadline)}',
        tz.TZDateTime.from(deadline, tz.UTC),
        const NotificationDetails(android: _eventDetails),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (_) {}
  }

  static Future<void> cancelTimer(int timerId) async {
    if (!_ready) return;
    await _plugin.cancel(timerId);
  }
}

/// Brings the status-bar notifications in line with the current DB state:
/// one ongoing notification per active timer (live chronometer while running,
/// static text while paused) plus a scheduled auto-stop alert when configured.
Future<void> syncTimerNotifications() async {
  final timers = await DB.getTimers();
  for (final t in timers) {
    if (!t.isTotalActive) continue;
    // Clear any stale scheduled auto-stop before re-showing/re-scheduling.
    await Notifications.cancelTimer(t.id);
    final stats = await computeStats(t);
    // Projected stop moment based on the day's worked time; null while paused
    // (a pause pushes the deadline back, so it is rescheduled on resume — the
    // remaining budget itself is kept and shown in the paused notification).
    DateTime? deadline;
    final projectedMs = await DB.getAutoStopProjectionMs(t);
    if (projectedMs != null) {
      deadline = DateTime.fromMillisecondsSinceEpoch(projectedMs);
    }
    if (t.isPartialActive) {
      await Notifications.showRunning(t, stats.partialToday, autoStopAt: deadline);
    } else {
      await Notifications.showPaused(t, stats.partialToday,
          autoStopRemaining: stats.autoStopRemaining, dayLabel: partialLabel(stats));
    }
    if (deadline != null) {
      await Notifications.scheduleAutoStop(t, deadline);
    }
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
  final int pieces;
  final int autoStopSec;

  /// Wall-clock instant the partial correction was entered for, or 0 when
  /// there is no correction. A correction fixes up one day's record, so the
  /// timer card applies it to that day only instead of to every day that
  /// follows.
  final int partialAdjustAtMs;

  /// Wall-clock instant at which the auto-stop last fired for this timer, or 0
  /// when it never did. Used to arm the limit once per work day: after it
  /// fired, a session the user deliberately starts again on the same day is
  /// left alone instead of being killed on the spot.
  final int autoStopDoneMs;

  WorkTimer({
    required this.id,
    required this.name,
    required this.product,
    required this.isTotalActive,
    required this.isPartialActive,
    required this.partialAdjustSec,
    required this.totalAdjustSec,
    required this.createdAtMs,
    required this.pieces,
    required this.autoStopSec,
    this.partialAdjustAtMs = 0,
    this.autoStopDoneMs = 0,
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
        pieces:
(m['pieces'] as int? ?? 0 ),
        autoStopSec: (m['auto_stop_sec'] as int? ?? 0),
        partialAdjustAtMs: (m['partial_adjust_at_ms'] as int? ?? 0),
        autoStopDoneMs: (m['auto_stop_done_ms'] as int? ?? 0),
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

/// Start of the calendar day [ms] falls into, in local time.
int startOfDayMs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// First instant of the work day an auto-stop limit is measured over.
///
/// Normally that is midnight of the current day, so every pause, stop and
/// restart during the day draws from the same budget — the whole point of an
/// "auto-stop after 7h" setting. A session that was opened on an earlier day
/// (a night shift) keeps the window anchored on the day it started in, so
/// midnight does not hand out a second budget mid-shift.
int autoStopWindowStartMs({required int sessionStartMs, required int nowMs}) {
  final today = startOfDayMs(nowMs);
  final sessionDay = startOfDayMs(sessionStartMs);
  return sessionDay < today ? sessionDay : today;
}

class DB {
  static Database? _db;
  static Future<Database>? _opening;

  /// Clock behind the auto-stop bookkeeping. Overridable so tests can place
  /// themselves inside a work day instead of waiting for one.
  @visibleForTesting
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// Single-flight database handle. Several screens hit this concurrently on
  /// the first frame; without the [_opening] guard each of them would start
  /// its own [openDatabase] and run the migrations in parallel.
  static Future<Database> get database {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  static Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dbPath, 'work_timer.db'),
      version: 9,
      onConfigure: (db) async {
        // Must happen outside a transaction, which is why it lives here and
        // not in onCreate/onUpgrade. Without it the ON DELETE CASCADE
        // constraints below are silently inert.
        await db.execute('PRAGMA foreign_keys = ON');
      },
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
            created_at_ms INTEGER NOT NULL,
            pieces INTEGER NOT NULL DEFAULT 0,
            auto_stop_sec INTEGER NOT NULL DEFAULT 0,
            auto_stop_done_ms INTEGER NOT NULL DEFAULT 0,
            partial_adjust_at_ms INTEGER NOT NULL DEFAULT 0
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
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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
            // Foreign keys are enforced now, so an entry pointing at a
            // deleted timer would abort the whole upgrade. Skip those.
            final liveTimerIds = {
              for (final r in await db.query('timers', columns: ['id'])) r['id'] as int,
            };
            final oldEntries = await db.query('time_entries');
            for (final e in oldEntries) {
              if (!liveTimerIds.contains(e['timer_id'] as int?)) continue;
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

        if (oldVersion < 5) {
          await db.execute('ALTER TABLE timers ADD COLUMN pieces INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        }

        if (oldVersion < 6) {
          await db.execute('ALTER TABLE timers ADD COLUMN auto_stop_sec INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        }

        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }

        if (oldVersion < 8) {
          await db.execute('ALTER TABLE timers ADD COLUMN auto_stop_done_ms INTEGER NOT NULL DEFAULT 0').catchError((_) {});
        }

        if (oldVersion < 9) {
          await db.execute('ALTER TABLE timers ADD COLUMN partial_adjust_at_ms INTEGER NOT NULL DEFAULT 0').catchError((_) {});
          // Corrections entered before this version carry no date. Pin them to
          // the timer's last recorded work, which is the day they were meant
          // to fix, so they stop being re-applied to every following day.
          await db.rawUpdate('''
            UPDATE timers SET partial_adjust_at_ms = COALESCE(
              (SELECT MAX(COALESCE(end_at_ms, start_at_ms)) FROM partial_segments
                WHERE partial_segments.timer_id = timers.id),
              created_at_ms)
            WHERE partial_adjust_sec != 0
          ''');
        }
      },
    );
    _db = db;
    return db;
  }

  static Future<List<WorkTimer>> getTimers() async {
    final db = await database;
    final autoStopped = await _enforceAutoStops(db);
    final rows = await db.query('timers', orderBy: 'id DESC');
    final timers = rows.map(WorkTimer.fromMap).toList();
    for (final stop in autoStopped) {
      for (final t in timers) {
        if (t.id == stop.$1) {
          await Notifications.showAutoStopped(t, DateTime.fromMillisecondsSinceEpoch(stop.$2));
          break;
        }
      }
    }
    return timers;
  }

  /// Closes sessions of active timers once the *worked* time of the current
  /// work day (partial segments, i.e. excluding pauses) reaches the auto-stop
  /// limit. The budget belongs to the day, not to a single session: pausing
  /// over lunch, or stopping and starting the timer again, carries the
  /// already-worked time along instead of handing out a fresh limit.
  /// The session ends exactly at the instant the limit was reached (not
  /// "now"), so recorded time stays correct even when the app was closed
  /// meanwhile. Returns (timerId, stoppedAtMs) for every timer that stopped.
  static Future<List<(int, int)>> _enforceAutoStops(Database db) async {
    final now = nowMs();
    final rows = await db.rawQuery('''
      SELECT t.id AS timer_id, t.auto_stop_sec AS auto_stop_sec,
             t.auto_stop_done_ms AS auto_stop_done_ms,
             s.id AS session_id, s.start_at_ms AS start_at_ms
      FROM timers t
      JOIN total_sessions s ON s.timer_id = t.id AND s.end_at_ms IS NULL
      WHERE t.is_total_active = 1 AND t.auto_stop_sec > 0
    ''');

    final stopped = <(int, int)>[];
    for (final r in rows) {
      final timerId = r['timer_id'] as int;
      final limitMs = (r['auto_stop_sec'] as int) * 1000;
      final sessionStart = r['start_at_ms'] as int;
      final windowStart = autoStopWindowStartMs(sessionStartMs: sessionStart, nowMs: now);
      // The limit fires once per work day. A session started after it already
      // fired is the user's deliberate overtime and stays untouched.
      if ((r['auto_stop_done_ms'] as int? ?? 0) >= windowStart) continue;
      final (_, reachedAt) = await _workedSinceMs(db, timerId, windowStart, now, limitMs: limitMs);
      if (reachedAt == null) continue;
      if (reachedAt <= sessionStart) {
        // The day's budget was already spent before this session was opened,
        // so there is nothing of this session to cut off. Arm the limit for
        // the next day and leave the running session alone rather than
        // deleting time the user knowingly worked.
        await db.update('timers', {'auto_stop_done_ms': now}, where: 'id = ?', whereArgs: [timerId]);
        continue;
      }
      await db.update(
        'timers',
        {'is_total_active': 0, 'is_partial_active': 0, 'auto_stop_done_ms': reachedAt},
        where: 'id = ?',
        whereArgs: [timerId],
      );
      await db.update('total_sessions', {'end_at_ms': reachedAt}, where: 'id = ?', whereArgs: [r['session_id']]);
      // Trim every segment that extends past the limit, not just those
      // starting before it. An open segment that started later would
      // otherwise stay open forever on a timer that is no longer active and
      // keep counting up to "now"; a closed one would record worked time past
      // the point where the session already ended. MAX() collapses a segment
      // that begins after the limit to zero length. The comparison has to
      // include equality, or a segment still open at the very moment the
      // limit is reached (worked time hitting the limit exactly now) would be
      // left open on a stopped timer.
      await db.rawUpdate(
        'UPDATE partial_segments SET end_at_ms = MAX(start_at_ms, ?) '
        'WHERE timer_id = ? AND COALESCE(end_at_ms, ?) >= ?',
        [reachedAt, timerId, now, reachedAt],
      );
      stopped.add((timerId, reachedAt));
    }
    return stopped;
  }

  /// Sums the worked time (partial segments, pauses excluded) of a timer from
  /// [windowStartMs] onwards, with open segments counted up to [nowMs]. All
  /// segments in the window count, no matter which session they belong to, so
  /// stopping and starting the timer again does not reset the tally.
  /// When [limitMs] is given, also returns the exact instant the accumulated
  /// worked time reached that limit (null if not reached).
  static Future<(int, int?)> _workedSinceMs(
    DatabaseExecutor db,
    int timerId,
    int windowStartMs,
    int nowMs, {
    int? limitMs,
  }) async {
    final segs = await db.query(
      'partial_segments',
      columns: ['start_at_ms', 'end_at_ms'],
      where: 'timer_id = ? AND COALESCE(end_at_ms, ?) > ?',
      whereArgs: [timerId, nowMs, windowStartMs],
      orderBy: 'start_at_ms ASC',
    );
    var worked = 0;
    int? reachedAt;
    for (final s in segs) {
      var start = s['start_at_ms'] as int;
      if (start < windowStartMs) start = windowStartMs;
      final end = (s['end_at_ms'] as int?) ?? nowMs;
      if (end <= start) continue;
      if (limitMs != null && reachedAt == null && worked + (end - start) >= limitMs) {
        reachedAt = start + (limitMs - worked);
      }
      worked += end - start;
    }
    return (worked, reachedAt);
  }

  /// Worked time left before a timer hits its auto-stop limit, counted over
  /// the whole work day (see [autoStopWindowStartMs]) rather than the current
  /// session. Null when there is no limit, no open session, or the limit
  /// already fired for this day.
  static Future<Duration?> getAutoStopRemaining(WorkTimer t) async {
    if (t.autoStopSec <= 0 || !t.isTotalActive) return null;
    final db = await database;
    final startMs = await getOpenTotalSessionStartMs(t.id);
    if (startMs == null) return null;
    final now = nowMs();
    final windowStart = autoStopWindowStartMs(sessionStartMs: startMs, nowMs: now);
    if (t.autoStopDoneMs >= windowStart) return null;
    final (worked, _) = await _workedSinceMs(db, t.id, windowStart, now);
    final remaining = t.autoStopSec * 1000 - worked;
    return Duration(milliseconds: remaining <= 0 ? 0 : remaining);
  }

  /// Projected wall-clock instant at which a running timer will hit its
  /// worked-time auto-stop limit. Null when the timer has no live limit or is
  /// paused (a paused timer accumulates no worked time, so it has no fixed
  /// deadline until it resumes).
  static Future<int?> getAutoStopProjectionMs(WorkTimer t) async {
    if (!t.isPartialActive) return null;
    final remaining = await getAutoStopRemaining(t);
    if (remaining == null) return null;
    return nowMs() + remaining.inMilliseconds;
  }

  static Future<int?> getOpenTotalSessionStartMs(int timerId) async {
    final db = await database;
    final rows = await db.query(
      'total_sessions',
      columns: ['start_at_ms'],
      where: 'timer_id = ? AND end_at_ms IS NULL',
      whereArgs: [timerId],
      orderBy: 'start_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['start_at_ms'] as int?;
  }

  static Future<int> createTimer(String name, String product, {int autoStopSec = 0}) async {
    final db = await database;
    return db.insert('timers', {
      'name': name.trim(),
      'product': product.trim(),
      'is_total_active': 0,
      'is_partial_active': 0,
      'partial_adjust_sec': 0,
      'total_adjust_sec': 0,
      'created_at_ms': DateTime.now().millisecondsSinceEpoch,
      'pieces': 0,
      'auto_stop_sec': autoStopSec,
      'auto_stop_done_ms': 0,
      'partial_adjust_at_ms': 0,
    });
  }

  static Future<void> updateTimer(
    int id,
    String name,
    String product, {
    int? partialAdjustSec,
    int? totalAdjustSec,
    int? createdAtMs,
    int? pieces,
    int? autoStopSec,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final values = <String, Object?>{'name': name.trim(), 'product': product.trim()};
      if (partialAdjustSec != null) {
        values['partial_adjust_sec'] = partialAdjustSec;
        final row = await txn.query('timers',
            columns: ['partial_adjust_sec'], where: 'id = ?', whereArgs: [id], limit: 1);
        final oldAdjust = row.isEmpty ? null : row.first['partial_adjust_sec'] as int?;
        // Date the correction when it actually changes, so re-saving the
        // dialog for an unrelated field does not move it to another day.
        if (oldAdjust != partialAdjustSec) {
          values['partial_adjust_at_ms'] = partialAdjustSec == 0 ? 0 : nowMs();
        }
      }
      if (totalAdjustSec != null) values['total_adjust_sec'] = totalAdjustSec;
      if (pieces != null)
values['pieces'] = pieces;
      if (autoStopSec != null) {
        values['auto_stop_sec'] = autoStopSec;
        final row = await txn.query('timers',
            columns: ['auto_stop_sec'], where: 'id = ?', whereArgs: [id], limit: 1);
        final oldAutoStopSec = row.isEmpty ? null : row.first['auto_stop_sec'] as int?;
        // A changed limit is a new decision: arm it again even if today's
        // auto-stop already fired.
        if (oldAutoStopSec != autoStopSec) values['auto_stop_done_ms'] = 0;
      }
      if (createdAtMs != null) {
        // Shift recorded time only by how much the created date actually
        // changed. Anchoring on the first session start instead moved all
        // sessions on every save, even when the date was left untouched.
        final row = await txn.query('timers',
            columns: ['created_at_ms'], where: 'id = ?', whereArgs: [id], limit: 1);
        final oldCreatedAtMs = row.isEmpty ? null : row.first['created_at_ms'] as int?;
        final delta = oldCreatedAtMs == null ? 0 : createdAtMs - oldCreatedAtMs;

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

  /// Opens a partial segment unless one is already open. Reusing an open
  /// segment keeps start/resume idempotent: two of them in flight at once
  /// (double tap, or a stale `is_partial_active` in the UI snapshot) would
  /// otherwise leave two open segments, and today's time would run at 2x.
  static Future<void> _openPartialSegment(DatabaseExecutor txn, int timerId, int nowMs) async {
    final open = await txn.query('partial_segments',
        columns: ['id'], where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId], limit: 1);
    if (open.isNotEmpty) return;
    await txn.insert('partial_segments', {'timer_id': timerId, 'start_at_ms': nowMs, 'end_at_ms': null});
  }

  /// Closes every open segment/session of a timer, so a leaked row from an
  /// earlier version cannot keep accumulating time after the timer stopped.
  static Future<void> _closeOpenRows(DatabaseExecutor txn, String table, int timerId, int nowMs) async {
    await txn.rawUpdate(
      'UPDATE $table SET end_at_ms = MAX(start_at_ms, ?) WHERE timer_id = ? AND end_at_ms IS NULL',
      [nowMs, timerId],
    );
  }

  static Future<void> start(int timerId) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final openSession = await txn.query('total_sessions',
          columns: ['id'], where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId], limit: 1);
      if (openSession.isEmpty) {
        await txn.insert('total_sessions', {'timer_id': timerId, 'start_at_ms': now, 'end_at_ms': null});
      }
      await _openPartialSegment(txn, timerId, now);
      await txn.update('timers', {'is_total_active': 1, 'is_partial_active': 1},
          where: 'id = ?', whereArgs: [timerId]);
    });
  }

  static Future<void> pausePartial(int timerId) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _closeOpenRows(txn, 'partial_segments', timerId, now);
      await txn.update('timers', {'is_partial_active': 0}, where: 'id = ?', whereArgs: [timerId]);
    });
  }

  static Future<void> resumePartial(int timerId) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _openPartialSegment(txn, timerId, now);
      await txn.update('timers', {'is_partial_active': 1}, where: 'id = ?', whereArgs: [timerId]);
    });
  }

  static Future<void> stop(int timerId) async {
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _closeOpenRows(txn, 'partial_segments', timerId, now);
      await _closeOpenRows(txn, 'total_sessions', timerId, now);
      await txn.update('timers', {'is_total_active': 0, 'is_partial_active': 0},
          where: 'id = ?', whereArgs: [timerId]);
    });
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

  static const _weeklyTargetKey = 'weekly_target_sec';

  static Future<int> getWeeklyTargetSec() async {
    final db = await database;
    final rows = await db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [_weeklyTargetKey], limit: 1);
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  static Future<void> setWeeklyTargetSec(int seconds) async {
    final db = await database;
    await db.insert(
      'settings',
      {'key': _weeklyTargetKey, 'value': seconds.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteReportEntry({
    required int timerId,
    required int totalSessionId,
    required int sessionStartMs,
    required int sessionEndMs,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final row = await txn.query('total_sessions',
          columns: ['end_at_ms'], where: 'id = ?', whereArgs: [totalSessionId], limit: 1);
      if (row.isEmpty) return;
      final wasRunning = row.first['end_at_ms'] == null;

      await txn.delete('total_sessions', where: 'id = ?', whereArgs: [totalSessionId]);
      // An open segment belongs to this session too, so treat its end as the
      // session end instead of its own start (which would exclude it).
      await txn.rawDelete(
        '''
        DELETE FROM partial_segments
        WHERE timer_id = ?
          AND start_at_ms >= ?
          AND COALESCE(end_at_ms, ?) <= ?
        ''',
        [timerId, sessionStartMs, sessionEndMs, sessionEndMs],
      );

      // Deleting the session that is currently running would otherwise leave
      // the timer flagged active with nothing open to record into: the card
      // keeps showing "Running" and no button but Stop can recover it.
      if (wasRunning) {
        await txn.update('timers', {'is_total_active': 0, 'is_partial_active': 0},
            where: 'id = ?', whereArgs: [timerId]);
      }
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

/// Like [fmt] but keeps a leading '-' for negative durations
/// (fmt itself garbles them because each unit is negative).
String fmtSigned(Duration d) => d.isNegative ? '-${fmt(-d)}' : fmt(d);

/// Formats a plus/minus balance with an explicit sign: '+01:30:00' / '-01:30:00'.
String fmtBalance(Duration d) => d.isNegative ? '-${fmt(-d)}' : '+${fmt(d)}';

/// Monday 00:00 of the week containing [d].
DateTime weekStartOf(DateTime d) =>
    DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

/// ISO-8601 week number (1..53) of the week containing [date].
///
/// The week is numbered by the calendar year its Thursday falls in. Counting
/// with calendar fields and a UTC day difference (rather than [Duration] on
/// local dates) keeps this exact across DST changes, where a local "day" is
/// 23 or 25 hours long and truncating to whole days loses one.
int isoWeekNumber(DateTime date) {
  final thursday = DateTime(date.year, date.month, date.day + (4 - date.weekday));
  final jan1 = DateTime.utc(thursday.year, 1, 1);
  final thursdayUtc = DateTime.utc(thursday.year, thursday.month, thursday.day);
  return thursdayUtc.difference(jan1).inDays ~/ 7 + 1;
}

/// Parses an hours-first work-time input, unlike [parseDurationInputToSeconds]
/// (which reads bare numbers as seconds and 'MM:SS'): '40' = 40h,
/// '38.5'/'38,5' = 38h30m, '38:30' = 38h30m, '38:30:15' = HH:MM:SS.
int parseHoursFirstDurationToSeconds(String input) {
  final v = input.trim().replaceAll(',', '.');
  if (v.isEmpty) return 0;
  if (v.contains(':')) {
    final parts = v.split(':').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 3600 + parts[1] * 60;
    return 0;
  }
  final hours = double.tryParse(v) ?? 0;
  return (hours * 3600).round();
}

/// Parses a weekly work-time target. See [parseHoursFirstDurationToSeconds].
int parseWeeklyTargetToSeconds(String input) => parseHoursFirstDurationToSeconds(input);

/// Parses an auto-stop limit. Hours-first like the weekly target — the field
/// is prefilled as HH:MM:SS, so reading a bare '8' as eight *seconds* (what
/// [parseDurationInputToSeconds] does) would silently kill sessions on start.
/// Negative input means "off".
int parseAutoStopToSeconds(String input) {
  final seconds = parseHoursFirstDurationToSeconds(input);
  return seconds < 0 ? 0 : seconds;
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
  var v = input.trim();
  if (v.isEmpty) return 0;
  var sign = 1;
  if (v.startsWith('-')) {
    sign = -1;
    v = v.substring(1).trim();
  } else if (v.startsWith('+')) {
    v = v.substring(1).trim();
  }
  if (v.isEmpty) return 0;
  if (v.contains(':')) {
    final parts = v.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    if (parts.length == 2) return sign * (parts[0] * 60 + parts[1]);
  }
  return sign * (int.tryParse(v) ?? 0);
}

class TimerStats {
  final Duration partialToday;
  final Duration totalAllTime;

  /// Day the [partialToday] figure belongs to. Normally the current work day;
  /// when nothing was worked in it, the last day that has recorded time, so a
  /// timer that ran yesterday keeps showing yesterday's hours instead of a
  /// bare 0:00:00 while the reports still list them.
  final DateTime partialDay;

  /// Worked time left before the auto-stop limit closes the running session,
  /// or null when the timer has no limit armed right now (no limit set, not
  /// running, or the limit already fired for this work day).
  final Duration? autoStopRemaining;

  const TimerStats({
    required this.partialToday,
    required this.totalAllTime,
    required this.partialDay,
    this.autoStopRemaining,
  });
}

Future<TimerStats> computeStats(WorkTimer timer) async {
  final partialSegs = await DB.getPartialSegmentsForTimer(timer.id);
  final totalSegs = await DB.getTotalSessionsForTimer(timer.id);
  final now = DateTime.fromMillisecondsSinceEpoch(DB.nowMs());
  final openSessionStartMs = await DB.getOpenTotalSessionStartMs(timer.id);
  // Same work day the auto-stop budget uses: midnight, unless a session that
  // began on an earlier day is still open (night shift), in which case the day
  // it started in. Otherwise midnight would cut a running shift in half.
  final dayStart = DateTime.fromMillisecondsSinceEpoch(openSessionStartMs == null
      ? startOfDayMs(now.millisecondsSinceEpoch)
      : autoStopWindowStartMs(sessionStartMs: openSessionStartMs, nowMs: now.millisecondsSinceEpoch));

  Duration workedBetween(DateTime from, DateTime to) {
    var sum = Duration.zero;
    for (final s in partialSegs) {
      final end = s.endAt ?? now;
      if (!end.isAfter(s.startAt)) continue;
      sum += overlapDuration(rangeStart: from, rangeEnd: to, segStart: s.startAt, segEnd: end);
    }
    return sum;
  }

  var partialDay = dayStart;
  var partialToday = workedBetween(dayStart, now);

  if (partialToday == Duration.zero && !timer.isPartialActive) {
    // Nothing worked in the current day. Fall back to the last day that has
    // recorded time instead of showing 0:00:00 for work the reports still
    // list; the card names the day it is showing.
    DateTime? lastEnd;
    for (final s in partialSegs) {
      final end = s.endAt ?? now;
      if (!end.isAfter(s.startAt)) continue;
      if (lastEnd == null || end.isAfter(lastEnd)) lastEnd = end;
    }
    if (lastEnd != null && lastEnd.isBefore(dayStart)) {
      partialDay = DateTime(lastEnd.year, lastEnd.month, lastEnd.day);
      partialToday = workedBetween(partialDay, partialDay.add(const Duration(days: 1)));
    }
  }

  // A correction fixes up the day it was entered for. Applying it to every
  // later day too would inflate them, or — for a correction that subtracts
  // time — pin them at 0:00:00 forever.
  if (timer.partialAdjustSec != 0 &&
      startOfDayMs(timer.partialAdjustAtMs) == partialDay.millisecondsSinceEpoch) {
    partialToday += Duration(seconds: timer.partialAdjustSec);
  }

  Duration totalAllTime = Duration.zero;
  for (final s in totalSegs) {
    final end = s.endAt ?? now;
    if (!end.isAfter(s.startAt)) continue;
    totalAllTime += end.difference(s.startAt);
  }
  totalAllTime += Duration(seconds: timer.totalAdjustSec);

  if (partialToday.isNegative) partialToday = Duration.zero;
  if (totalAllTime.isNegative) totalAllTime = Duration.zero;

  return TimerStats(
    partialToday: partialToday,
    totalAllTime: totalAllTime,
    partialDay: partialDay,
    autoStopRemaining: await DB.getAutoStopRemaining(timer),
  );
}

/// Label for the timer card's partial line: 'today' for the current work day,
/// the date itself for an older one that is being shown because nothing was
/// worked today.
String partialLabel(TimerStats? stats) {
  if (stats == null) return 'today';
  final today = startOfDayMs(DB.nowMs());
  if (stats.partialDay.millisecondsSinceEpoch >= today) return 'today';
  final d = stats.partialDay;
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.';
}

/// Dashboard line for an active timer: its state plus how much of today's
/// auto-stop budget is left, when a limit is armed.
String _dashboardSubtitle(WorkTimer t, TimerStats? stats) {
  final label = partialLabel(stats);
  // Only worth naming when it is not the current day — that is when the
  // figure beside it would otherwise look like time worked today.
  final state = (t.isPartialActive ? 'Running' : 'Paused') + (label == 'today' ? '' : ' • $label');
  final remaining = stats?.autoStopRemaining;
  if (remaining == null) return state;
  return '$state • ${fmt(remaining)} left before auto-stop';
}

/// Card line describing the auto-stop limit and what is left of today's
/// budget. The limit covers the whole work day, so pausing over lunch or
/// stopping and starting again keeps counting down the same budget.
String _autoStopLine(WorkTimer t, TimerStats? stats) {
  final limit = 'Auto-stop after ${fmt(Duration(seconds: t.autoStopSec))} worked time per day';
  // While the stats are still loading there is nothing to say about the
  // budget yet — saying "already reached" for that frame would be a lie.
  if (!t.isTotalActive || stats == null) return limit;
  final remaining = stats.autoStopRemaining;
  if (remaining == null) return '$limit • already reached today';
  return '$limit • ${fmt(remaining)} left today';
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
    final partialCtrl = TextEditingController(text: timer == null ? '0' : fmtSigned(Duration(seconds: timer.partialAdjustSec)));
    final totalCtrl = TextEditingController(text: timer == null ? '0' : fmtSigned(Duration(seconds: timer.totalAdjustSec)));
    final autoStopCtrl = TextEditingController(
        text: timer == null || timer.autoStopSec <= 0 ? '' : fmt(Duration(seconds: timer.autoStopSec)));
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
        // Keep seconds/ms: dropping them would make "created" differ from the
        // stored value by up to a minute even when the date was not changed,
        // and updateTimer shifts every session by exactly that difference.
        selectedCreated = DateTime(
          picked.year,
          picked.month,
          picked.day,
          selectedCreated.hour,
          selectedCreated.minute,
          selectedCreated.second,
          selectedCreated.millisecond,
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
          selectedCreated.second,
          selectedCreated.millisecond,
        );
        setLocal(() {});
      }
    }

    Future<void> pickCorrection(TextEditingController ctrl, {bool keepSign = false}) async {
      final negative = keepSign && ctrl.text.trim().startsWith('-');
      final picked = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 0, minute: 0),
      );
      if (picked != null) {
        ctrl.text = '${negative ? '-' : ''}${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}:00';
      }
    }

    void toggleSign(TextEditingController ctrl, StateSetter setLocal) {
      var t = ctrl.text.trim();
      if (t.startsWith('-')) {
        t = t.substring(1).trim();
      } else if (parseDurationInputToSeconds(t) != 0) {
        t = '-${t.startsWith('+') ? t.substring(1).trim() : t}';
      }
      ctrl.text = t;
      setLocal(() {});
    }

    Widget correctionSuffix(TextEditingController ctrl, StateSetter setLocal) {
      final negative = ctrl.text.trim().startsWith('-');
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: negative ? 'Subtracting — tap to add instead' : 'Adding — tap to subtract instead',
            onPressed: () => toggleSign(ctrl, setLocal),
            icon: Icon(negative ? Icons.remove_circle_outline : Icons.add_circle_outline),
          ),
          IconButton(onPressed: () => pickCorrection(ctrl, keepSign: true), icon: const Icon(Icons.schedule)),
        ],
      );
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
                TextField(
                  controller: autoStopCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Auto-stop after worked time per day (hours: 8, 7.5 or 08:30 — empty = off)',
                    suffixIcon: IconButton(onPressed: () => pickCorrection(autoStopCtrl), icon: const Icon(Icons.timer_off)),
                  ),
                ),
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
                    onChanged: (_) => setLocal(() {}),
                    decoration: InputDecoration(
                      labelText: 'Partial correction (±HH:MM:SS or seconds)',
                      suffixIcon: correctionSuffix(partialCtrl, setLocal),
                    ),
                  ),
                  TextField(
                    controller: totalCtrl,
                    onChanged: (_) => setLocal(() {}),
                    decoration: InputDecoration(
                      labelText: 'Total correction (±HH:MM:SS or seconds)',
                      suffixIcon: correctionSuffix(totalCtrl, setLocal),
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
                final autoStopSec = parseAutoStopToSeconds(autoStopCtrl.text);
                if (timer == null) {
                  await DB.createTimer(n, p, autoStopSec: autoStopSec);
                } else {
                  await DB.updateTimer(
                    timer.id,
                    n,
                    p,
                    partialAdjustSec: parseDurationInputToSeconds(partialCtrl.text),
                    totalAdjustSec: parseDurationInputToSeconds(totalCtrl.text),
                    createdAtMs: selectedCreated.millisecondsSinceEpoch,
                    autoStopSec: autoStopSec,
                  );
                }
                await syncTimerNotifications();
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
  Future<void> _piecesDialog(WorkTimer t) async {
    // 1. Controller erstellt und lädt die aktuelle Stückzahl
    final ctrl = TextEditingController(text: t.pieces.toString());

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stücke eintragen'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number, // Öffnet direkt den Ziffernblock am Handy
          decoration: const InputDecoration(labelText: 'Anzahl'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              // 2. Textfeld auslesen und in eine Zahl verwandeln
              final newPieces = int.tryParse(ctrl.text.trim()) ?? 0;
              
              // 3. DEINE AUFGABE: Datenbank aktualisieren!
              // HIER FEHLT DER CODE
             await DB.updateTimer(t.id, t.name, t.product, pieces: newPieces);

              
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {}); // App-Anzeige aktualisieren
              }
            },
            child: const Text('Speichern'),
          ),
        ],
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
    await syncTimerNotifications();
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
                      
                      String avgText = t.pieces > 0 ? fmt(Duration(seconds: (partial.inSeconds / t.pieces).round())) : '---';
                      
                      final primaryLabel = !t.isTotalActive ? 'Start' : (t.isPartialActive ? 'Pause' : 'Resume');
                      final primaryIcon = !t.isTotalActive ? Icons.play_arrow : (t.isPartialActive ? Icons.pause : Icons.play_arrow);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                          Text('Product: ${t.product}'),
                          Text('Created: ${fmtDateTime(DateTime.fromMillisecondsSinceEpoch(t.createdAtMs))}'),
                          const SizedBox(height: 8),
                          Text('Partial (${partialLabel(statsSnap.data)}): ${fmt(partial)}'),
                          Text('Total (all-time): ${fmt(total)}'),
Text('Stücke: ${t.pieces} | Schnitt: $avgText'),
                          if (t.autoStopSec > 0)
                            Text(_autoStopLine(t, statsSnap.data)),

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
                                        await Notifications.cancelTimer(t.id);
                                        setState(() {});
                                      }
                                    : null,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop'),
                              ),
                              OutlinedButton.icon(onPressed: () => _piecesDialog(t), icon: const Icon(Icons.add_box), label: const Text('Stück')),
                              OutlinedButton.icon(onPressed: () => _timerDialog(timer: t), icon: const Icon(Icons.edit), label: const Text('Edit')),
                              TextButton.icon(
                                onPressed: () async {
                                  await DB.stop(t.id);
                                  await DB.deleteTimer(t.id);
                                  await Notifications.cancelTimer(t.id);
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

Future<List<ReportLine>> buildReportLines(DateTime rangeStart, DateTime rangeEnd) async {
  final timers = await DB.getTimers();
  final timerById = {for (final t in timers) t.id: t};

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

/// Worked time per week (Monday-keyed) summed from report lines.
Map<DateTime, Duration> workedPerWeek(List<ReportLine> lines) {
  final byWeek = <DateTime, Duration>{};
  for (final l in lines) {
    final wk = weekStartOf(l.start);
    byWeek[wk] = (byWeek[wk] ?? Duration.zero) + l.partial;
  }
  return byWeek;
}

class _DashboardData {
  final List<WorkTimer> activeTimers;
  final Map<int, TimerStats> activeStats;
  final int weeklyTargetSec;
  final Duration workedThisWeek;

  _DashboardData({
    required this.activeTimers,
    required this.activeStats,
    required this.weeklyTargetSec,
    required this.workedThisWeek,
  });
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
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

  Future<_DashboardData> _load() async {
    final timers = await DB.getTimers();
    final active = timers.where((t) => t.isTotalActive).toList();
    final activeStats = <int, TimerStats>{};
    for (final t in active) {
      activeStats[t.id] = await computeStats(t);
    }
    final targetSec = await DB.getWeeklyTargetSec();
    final now = DateTime.now();
    final lines = await buildReportLines(weekStartOf(now), now);
    final worked = lines.fold<Duration>(Duration.zero, (a, b) => a + b.partial);
    return _DashboardData(
      activeTimers: active,
      activeStats: activeStats,
      weeklyTargetSec: targetSec,
      workedThisWeek: worked,
    );
  }

  Future<void> _editWeeklyTarget(int currentSec) async {
    final ctrl = TextEditingController(
      text: currentSec <= 0
          ? ''
          : '${currentSec ~/ 3600}:${((currentSec % 3600) ~/ 60).toString().padLeft(2, '0')}',
    );
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wochenstunden (Soll)'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Stunden pro Woche (z.B. 40, 38,5 oder 38:30)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await DB.setWeeklyTargetSec(parseWeeklyTargetToSeconds(ctrl.text));
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {});
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: FutureBuilder<_DashboardData>(
        future: _load(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          final target = Duration(seconds: data.weeklyTargetSec);
          final balance = data.workedThisWeek - target;

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Diese Woche', style: Theme.of(context).textTheme.titleMedium),
                          ),
                          IconButton(
                            tooltip: 'Wochenstunden festlegen',
                            onPressed: () => _editWeeklyTarget(data.weeklyTargetSec),
                            icon: const Icon(Icons.edit),
                          ),
                        ],
                      ),
                      Text('Gearbeitet: ${fmt(data.workedThisWeek)}'),
                      if (data.weeklyTargetSec > 0) ...[
                        Text('Soll: ${fmt(target)}'),
                        Text(
                          '${balance.isNegative ? 'Minusstunden' : 'Plusstunden'}: ${fmtBalance(balance)}',
                          style: TextStyle(
                            color: balance.isNegative ? Colors.red : Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ] else
                        const Text('Keine Wochenstunden hinterlegt — mit dem Stift festlegen, um Plus-/Minusstunden zu sehen.'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('Aktive Timer', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              if (data.activeTimers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Kein Timer läuft gerade.')),
                ),
              for (final t in data.activeTimers)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.circle, size: 14, color: t.isPartialActive ? Colors.green : Colors.orange),
                    title: Text('${t.name} • ${t.product}'),
                    subtitle: Text(_dashboardSubtitle(t, data.activeStats[t.id])),
                    trailing: Text(
                      fmt(data.activeStats[t.id]?.partialToday ?? Duration.zero),
                      style: Theme.of(context).textTheme.titleMedium,
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

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String period = 'today';
  DateTime selectedMonth = monthStart(DateTime.now());

  (DateTime, DateTime) _rangeNow() {
    final range = reportRangeFor(period: period, now: DateTime.now(), selectedMonth: selectedMonth);
    return (range.start, range.end);
  }

  String _monthLabel(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  bool _canGoToNextMonth() => monthStart(selectedMonth).isBefore(monthStart(DateTime.now()));

  void _shiftSelectedMonth(int delta) {
    final next = monthStart(DateTime(selectedMonth.year, selectedMonth.month + delta, 1));
    if (next.isAfter(monthStart(DateTime.now()))) return;
    setState(() => selectedMonth = next);
  }

  Future<void> _pickReportMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedMonth.isAfter(now) ? now : selectedMonth,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() => selectedMonth = monthStart(picked));
  }

  Future<List<ReportLine>> _buildReportLines() async {
    final (rangeStart, rangeEnd) = _rangeNow();
    return buildReportLines(rangeStart, rangeEnd);
  }

  Future<(List<ReportLine>, int)> _buildReportData() async {
    return (await _buildReportLines(), await DB.getWeeklyTargetSec());
  }

  DateTime _weekStart(DateTime d) => weekStartOf(d);

  String _safeName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  String _pdfFileName(List<ReportLine> lines) {
    final date = period == 'month' ? selectedMonth : DateTime.now();
    final day = period == 'month' ? '' : '-${date.day.toString().padLeft(2, '0')}';
    final ds = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}$day';
    final names = lines.map((e) => e.timer.name).toSet().toList();
    if (names.length == 1) return '${_safeName(names.first)}-$ds.pdf';
    return 'report-$ds.pdf';
  }

  Future<Uint8List> _buildPdfBytes(List<ReportLine> lines) async {
    final pdf = pw.Document();
    final (rangeStart, rangeEnd) = _rangeNow();
    final totalPartial = lines.fold<Duration>(Duration.zero, (a, b) => a + b.partial);
    final targetSec = await DB.getWeeklyTargetSec();
    final target = Duration(seconds: targetSec);

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
        final kw = isoWeekNumber(wk);
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
        if (targetSec > 0) {
          widgets.add(pw.Text('Plus-/Minusstunden (Soll ${fmt(target)}): ${fmtBalance(weekTotal - target)}'));
        }
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
    if (targetSec > 0 && period != 'today') {
      final balance = period == 'week'
          ? totalPartial - target
          : workedPerWeek(lines)
              .values
              .fold<Duration>(Duration.zero, (a, worked) => a + (worked - target));
      widgets.add(pw.Text('Plus-/Minusstunden gesamt: ${fmtBalance(balance)}'));
    }
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
      body: FutureBuilder<(List<ReportLine>, int)>(
        future: _buildReportData(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (lines, targetSec) = snap.data!;
          final target = Duration(seconds: targetSec);
          final totalPartial = lines.fold<Duration>(Duration.zero, (a, b) => a + b.partial);
          final Duration? balance = targetSec <= 0 || period == 'today'
              ? null
              : period == 'week'
                  ? totalPartial - target
                  : workedPerWeek(lines)
                      .values
                      .fold<Duration>(Duration.zero, (a, worked) => a + (worked - target));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (period == 'month') ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () => _shiftSelectedMonth(-1),
                              tooltip: 'Previous month',
                              icon: const Icon(Icons.chevron_left),
                            ),
                            OutlinedButton.icon(
                              onPressed: _pickReportMonth,
                              icon: const Icon(Icons.calendar_month),
                              label: Text(_monthLabel(selectedMonth)),
                            ),
                            IconButton(
                              onPressed: _canGoToNextMonth() ? () => _shiftSelectedMonth(1) : null,
                              tooltip: 'Next month',
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      const Text('Total partial time'),
                      Text(fmt(totalPartial)),
                      if (balance != null) ...[
                        const SizedBox(height: 4),
                        Text('Soll pro Woche: ${fmt(target)}'),
                        Text(
                          '${balance.isNegative ? 'Minusstunden' : 'Plusstunden'}: ${fmtBalance(balance)}',
                          style: TextStyle(
                            color: balance.isNegative ? Colors.red : Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
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
              if (lines.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No data yet.')),
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
                            // The session may have been the running one, in
                            // which case its ongoing notification is now stale.
                            await Notifications.cancelTimer(l.timer.id);
                            await syncTimerNotifications();
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
