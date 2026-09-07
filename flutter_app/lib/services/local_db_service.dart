import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:kisiplan/models/lesson.dart';

class LocalDbService {
  static const _dbName = 'szkolplan.db';
  static const _table = 'lessons';

  Database? _db;

  Future<Database> _database() async {
    if (_db != null) {
      return _db!;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    _db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day TEXT NOT NULL,
            start TEXT NOT NULL,
            end TEXT NOT NULL,
            subject TEXT NOT NULL,
            room TEXT NOT NULL,
            class_name TEXT NOT NULL DEFAULT '',
            is_substitution INTEGER NOT NULL DEFAULT 0,
            is_duty INTEGER NOT NULL DEFAULT 0,
            is_cancelled INTEGER NOT NULL DEFAULT 0,
            original_subject TEXT,
            original_room TEXT,
            original_class_name TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE $_table ADD COLUMN is_substitution INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE $_table ADD COLUMN original_subject TEXT');
          await db.execute('ALTER TABLE $_table ADD COLUMN original_room TEXT');
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE $_table ADD COLUMN class_name TEXT NOT NULL DEFAULT ''");
          await db.execute('ALTER TABLE $_table ADD COLUMN original_class_name TEXT');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE $_table ADD COLUMN is_duty INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE $_table ADD COLUMN is_cancelled INTEGER NOT NULL DEFAULT 0');
        }
      },
    );

    return _db!;
  }

  Future<void> replaceAll(Map<String, List<Lesson>> timetable) async {
    final db = await _database();
    final batch = db.batch();

    batch.delete(_table);

    timetable.forEach((day, lessons) {
      for (final lesson in lessons) {
        batch.insert(_table, {
          'day': day,
          'start': lesson.startString,
          'end': lesson.endString,
          'subject': lesson.subject,
          'room': lesson.room,
          'class_name': lesson.className,
          'is_substitution': lesson.isSubstitution ? 1 : 0,
          'is_duty': lesson.isDuty ? 1 : 0,
          'is_cancelled': lesson.isCancelled ? 1 : 0,
          'original_subject': lesson.originalSubject,
          'original_room': lesson.originalRoom,
          'original_class_name': lesson.originalClassName,
        });
      }
    });

    await batch.commit(noResult: true);
  }

  Future<Map<String, List<Lesson>>> readAll() async {
    final db = await _database();
    final rows = await db.query(_table, orderBy: 'day ASC, start ASC');

    final result = <String, List<Lesson>>{};
    for (final row in rows) {
      final day = (row['day'] ?? '').toString();
      result.putIfAbsent(day, () => []);
      result[day]!.add(
        Lesson.fromJson({
          'start': row['start'],
          'end': row['end'],
          'subject': row['subject'],
          'room': row['room'],
          'className': row['class_name'] ?? '',
          'isSubstitution': (row['is_substitution'] as int?) == 1,
          'isDuty': (row['is_duty'] as int?) == 1,
          'isCancelled': (row['is_cancelled'] as int?) == 1,
          'originalSubject': row['original_subject'],
          'originalRoom': row['original_room'],
          'originalClassName': row['original_class_name'],
        }),
      );
    }

    return result;
  }

  Future<void> clear() async {
    final db = await _database();
    await db.delete(_table);
  }
}
