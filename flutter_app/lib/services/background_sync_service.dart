import 'package:workmanager/workmanager.dart';
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/services/local_db_service.dart';
import 'package:kisiplan/services/notification_service.dart';
import 'package:kisiplan/services/timetable_service.dart';
import 'package:kisiplan/services/widget_service.dart';

const backgroundSyncTaskName = 'timetableBackgroundSync';

/// WorkManager entry point — runs in its own background isolate, separate
/// from the running app (if any). Must stay a top-level/static function.
@pragma('vm:entry-point')
void backgroundSyncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == backgroundSyncTaskName) {
      try {
        await BackgroundSyncService().syncAndNotify();
      } catch (_) {
        // A failed background sync (no network, session expired, ...) just
        // means we try again on the next scheduled run.
      }
    }
    return true;
  });
}

/// Periodically re-fetches the timetable in the background, notifies the
/// user if something changed since the last fetch (new substitution,
/// cancellation, duty, room change, ...), and refreshes the home screen
/// widget so it stays current even while the app isn't open.
class BackgroundSyncService {
  Future<void> syncAndNotify() async {
    final timetableService = TimetableService();
    if (!await timetableService.hasSavedCredentials()) return;

    final db = LocalDbService();
    final before = await db.readAll();

    final result = await timetableService.getTodayLessons();
    if (result.fromCache) return; // fetch failed — nothing new to report

    final after = result.weekTimetable;

    if (!_sameTimetable(before, after)) {
      await NotificationService().notifyPlanChanged();
    }

    await WidgetService().updateFromTodayLessons(result.lessons);
  }

  bool _sameTimetable(Map<String, List<Lesson>> a, Map<String, List<Lesson>> b) {
    final sigA = _signature(a);
    final sigB = _signature(b);
    return sigA.length == sigB.length && sigA.containsAll(sigB);
  }

  Set<String> _signature(Map<String, List<Lesson>> timetable) {
    final result = <String>{};
    timetable.forEach((day, lessons) {
      for (final l in lessons) {
        result.add(
          '$day|${l.startString}|${l.endString}|${l.subject}|${l.room}|${l.className}|'
          '${l.isSubstitution}|${l.isDuty}|${l.isCancelled}',
        );
      }
    });
    return result;
  }
}
