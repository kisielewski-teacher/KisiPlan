import 'package:home_widget/home_widget.dart';
import 'package:kisiplan/models/lesson.dart';

/// Pushes the current/next lesson to the Android home screen widget.
class WidgetService {
  static const _androidWidgetName = 'TimetableWidgetProvider';

  /// Computes the "now" state (current lesson, or the next upcoming one if
  /// none is running) from today's lessons and writes it to the widget.
  Future<void> updateFromTodayLessons(List<Lesson> todayLessons) async {
    final nowMinutes = _nowMinutes();
    final current = findCurrentLesson(todayLessons, nowMinutes);
    final next = current == null ? findNextLesson(todayLessons, nowMinutes) : null;
    await _write(current: current, next: next);
  }

  int _nowMinutes() {
    final now = DateTime.now();
    return now.hour * 60 + now.minute;
  }

  Future<void> _write({Lesson? current, Lesson? next}) async {
    final String status;
    final String subject;
    final String time;
    final String room;
    final String className;

    if (current != null) {
      status = 'Teraz';
      subject = current.subject;
      time = '${current.startString}-${current.endString}';
      room = current.room.isNotEmpty ? 'sala ${current.room}' : '';
      className = current.className;
    } else if (next != null) {
      status = 'Następnie';
      subject = next.subject;
      time = 'od ${next.startString}';
      room = next.room.isNotEmpty ? 'sala ${next.room}' : '';
      className = next.className;
    } else {
      status = 'Plan Mechanika';
      subject = 'Brak lekcji';
      time = '';
      room = '';
      className = '';
    }

    try {
      await HomeWidget.saveWidgetData<String>('status', status);
      await HomeWidget.saveWidgetData<String>('subject', subject);
      await HomeWidget.saveWidgetData<String>('time', time);
      await HomeWidget.saveWidgetData<String>('room', room);
      await HomeWidget.saveWidgetData<String>('className', className);
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    } catch (_) {
      // No widget placed on the home screen, or platform doesn't support
      // it (desktop/web) — updating is a no-op then, not an error.
    }
  }
}

/// Mirrors the lesson currently in progress, if any. Exposed as a top-level
/// helper so both [WidgetService] and background sync can share it, and so
/// it's independently unit-testable.
Lesson? findCurrentLesson(List<Lesson> lessons, int nowMinutes) {
  for (final lesson in lessons) {
    if (nowMinutes >= lesson.startMinutes && nowMinutes < lesson.endMinutes) {
      return lesson;
    }
  }
  return null;
}

/// The soonest upcoming lesson after [nowMinutes], or null if none remain.
Lesson? findNextLesson(List<Lesson> lessons, int nowMinutes) {
  Lesson? next;
  for (final lesson in lessons) {
    if (lesson.startMinutes > nowMinutes && (next == null || lesson.startMinutes < next.startMinutes)) {
      next = lesson;
    }
  }
  return next;
}
