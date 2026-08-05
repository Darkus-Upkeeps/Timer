import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:work_timer/main.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbPath = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dbPath, 'work_timer.db'));
  });

  Future<int> openRowCount(String table, int timerId) async {
    final db = await DB.database;
    final rows = await db.query(table,
        columns: ['id'], where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId]);
    return rows.length;
  }

  test('starting an already running timer does not open a second session', () async {
    final id = await DB.createTimer('Double start', 'Product');
    await DB.start(id);
    await DB.start(id);

    expect(await openRowCount('total_sessions', id), 1);
    expect(await openRowCount('partial_segments', id), 1);
  });

  test('two concurrent starts still open only one session', () async {
    final id = await DB.createTimer('Concurrent start', 'Product');
    await Future.wait([DB.start(id), DB.start(id)]);

    expect(await openRowCount('total_sessions', id), 1);
    expect(await openRowCount('partial_segments', id), 1);
  });

  test('resuming twice does not open a second partial segment', () async {
    final id = await DB.createTimer('Double resume', 'Product');
    await DB.start(id);
    await DB.pausePartial(id);
    await DB.resumePartial(id);
    await DB.resumePartial(id);

    expect(await openRowCount('partial_segments', id), 1);
  });

  test('stop closes every open row, including ones leaked by older versions', () async {
    final id = await DB.createTimer('Leaked rows', 'Product');
    await DB.start(id);

    final db = await DB.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('partial_segments', {'timer_id': id, 'start_at_ms': now, 'end_at_ms': null});
    await db.insert('total_sessions', {'timer_id': id, 'start_at_ms': now, 'end_at_ms': null});

    await DB.stop(id);

    expect(await openRowCount('partial_segments', id), 0);
    expect(await openRowCount('total_sessions', id), 0);
  });

  test('deleting the running session from a report deactivates the timer', () async {
    final id = await DB.createTimer('Running', 'Product');
    await DB.start(id);

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    await DB.deleteReportEntry(
      timerId: id,
      totalSessionId: session.id,
      sessionStartMs: session.startAt.millisecondsSinceEpoch,
      sessionEndMs: DateTime.now().millisecondsSinceEpoch,
    );

    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    expect(timer.isTotalActive, isFalse, reason: 'timer must not stay flagged as running');
    expect(timer.isPartialActive, isFalse);
    expect(await DB.getTotalSessionsForTimer(id), isEmpty);
    expect(await DB.getPartialSegmentsForTimer(id), isEmpty,
        reason: 'the open segment belongs to the deleted session');
  });

  test('deleting a finished session leaves other timers untouched', () async {
    final keep = await DB.createTimer('Keep', 'Product');
    await DB.start(keep);

    final id = await DB.createTimer('Finished', 'Product');
    await DB.start(id);
    await DB.stop(id);

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    await DB.deleteReportEntry(
      timerId: id,
      totalSessionId: session.id,
      sessionStartMs: session.startAt.millisecondsSinceEpoch,
      sessionEndMs: session.endAt!.millisecondsSinceEpoch,
    );

    final kept = (await DB.getTimers()).firstWhere((t) => t.id == keep);
    expect(kept.isTotalActive, isTrue);
    expect(await openRowCount('total_sessions', keep), 1);
    await DB.stop(keep);
  });

  test('auto-stop leaves no open segment and credits no time past the limit', () async {
    final id = await DB.createTimer('Auto stop', 'Product', autoStopSec: 60);
    final db = await DB.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionStart = now - 600000; // session opened ten minutes ago

    await db.update('timers', {'is_total_active': 1, 'is_partial_active': 1},
        where: 'id = ?', whereArgs: [id]);
    await db.insert('total_sessions',
        {'timer_id': id, 'start_at_ms': sessionStart, 'end_at_ms': null});
    // Five worked minutes, so the 60s limit was reached one minute in...
    await db.insert('partial_segments',
        {'timer_id': id, 'start_at_ms': sessionStart, 'end_at_ms': sessionStart + 300000});
    // ...then a pause, and a resume that opened a segment after the limit.
    await db.insert('partial_segments',
        {'timer_id': id, 'start_at_ms': sessionStart + 400000, 'end_at_ms': null});

    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    expect(timer.isTotalActive, isFalse);
    expect(await openRowCount('partial_segments', id), 0,
        reason: 'a segment left open on a stopped timer would count up forever');

    final segments = await DB.getPartialSegmentsForTimer(id);
    final worked = segments.fold<Duration>(
        Duration.zero, (a, s) => a + s.endAt!.difference(s.startAt));
    expect(worked, const Duration(seconds: 60));

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    expect(session.endAt!.millisecondsSinceEpoch, sessionStart + 60000);
  });
}
