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

  test('saving an edit without changing the created date must not move sessions', () async {
    final id = await DB.createTimer('Task', 'Product');
    await DB.start(id);
    await DB.stop(id);

    // Real-world state: the timer was created well before its first session
    // started (timer created in the morning, started later).
    final session = (await DB.getTotalSessionsForTimer(id)).single;
    final createdMs = session.startAt.millisecondsSinceEpoch - 3600000;
    final db = await DB.database;
    await db.update('timers', {'created_at_ms': createdMs}, where: 'id = ?', whereArgs: [id]);

    // What the edit dialog's Save button does when nothing was changed.
    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    await DB.updateTimer(id, timer.name, timer.product, createdAtMs: timer.createdAtMs);

    final after = (await DB.getTotalSessionsForTimer(id)).single;
    expect(after.startAt, session.startAt);
    expect(after.endAt, session.endAt);
    final seg = (await DB.getPartialSegmentsForTimer(id)).single;
    expect(seg.startAt, session.startAt);
  });

  test('changing the created date shifts sessions by exactly that amount', () async {
    final id = await DB.createTimer('Shifted', 'Product');
    await DB.start(id);
    await DB.stop(id);

    final before = (await DB.getTotalSessionsForTimer(id)).single;
    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    const shiftMs = 30 * 60 * 1000;
    await DB.updateTimer(id, timer.name, timer.product, createdAtMs: timer.createdAtMs - shiftMs);

    final after = (await DB.getTotalSessionsForTimer(id)).single;
    expect(after.startAt, before.startAt.subtract(const Duration(milliseconds: shiftMs)));
    expect(after.endAt, before.endAt!.subtract(const Duration(milliseconds: shiftMs)));
  });

  test('weekly target setting round-trips through the settings table', () async {
    expect(await DB.getWeeklyTargetSec(), 0);
    await DB.setWeeklyTargetSec(38 * 3600 + 1800);
    expect(await DB.getWeeklyTargetSec(), 38 * 3600 + 1800);
    await DB.setWeeklyTargetSec(40 * 3600);
    expect(await DB.getWeeklyTargetSec(), 40 * 3600);
  });
}
