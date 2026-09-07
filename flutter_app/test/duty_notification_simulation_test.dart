import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/models/lesson.dart';

// ---------------------------------------------------------------------------
// This file simulates the decision algorithm inside
// lib/services/notification_service.dart (scheduleWeekDutyNotifications and
// checkAndNotify). NotificationService itself cannot be unit-tested directly
// on a desktop test runner: `_platformSupported` gates every method behind
// `Platform.isAndroid || Platform.isIOS`, which is always false on the host
// running `flutter test`, and its notification plugin needs a real platform
// channel. Instead, the constants and decision logic below are copied
// verbatim from the production file (see line references in comments) and
// exercised as a standalone simulation, so at least the *algorithm* — the
// part most likely to have an off-by-one bug — is verified.
// ---------------------------------------------------------------------------

// Mirrors notification_service.dart's private constants.
const _breakEndingMinutes = 2; // NotificationService._breakEndingMinutes
const _dutyWarningLong = 10; // NotificationService._dutyWarningLong
const _dutyWarningShort = 5; // NotificationService._dutyWarningShort
const _longBreakMinutes = 15; // NotificationService._longBreakMinutes

/// Mirrors the warnMin selection loop inside
/// NotificationService.scheduleWeekDutyNotifications.
int computeDutyWarningMinutes(Lesson duty, List<Lesson> nonDuty) {
  if (nonDuty.isEmpty || duty.startMinutes <= nonDuty.first.startMinutes) {
    return _dutyWarningLong;
  }
  for (int i = 0; i < nonDuty.length - 1; i++) {
    final gap = nonDuty[i + 1].startMinutes - nonDuty[i].endMinutes;
    if (gap >= _longBreakMinutes &&
        duty.startMinutes >= nonDuty[i].endMinutes &&
        duty.startMinutes <= nonDuty[i + 1].startMinutes) {
      return _dutyWarningLong;
    }
  }
  return _dutyWarningShort;
}

/// Mirrors the "which lesson comes next during the current break" loop
/// inside NotificationService.checkAndNotify.
Lesson? findNextLessonDuringBreak(List<Lesson> lessons, int nowMinutes) {
  for (int i = 0; i < lessons.length; i++) {
    final l = lessons[i];
    if (nowMinutes >= l.endMinutes &&
        i + 1 < lessons.length &&
        nowMinutes < lessons[i + 1].startMinutes) {
      return lessons[i + 1];
    }
  }
  return null;
}

Lesson _lesson(String start, String end, {bool isDuty = false, String subject = 'Lekcja'}) {
  return Lesson.fromJson({
    'start': start,
    'end': end,
    'subject': subject,
    'room': '1',
    'isDuty': isDuty,
  });
}

class _FiredEvent {
  final int minute;
  final String type; // 'morning' | 'break_ending' | 'end_of_day'
  final String key;
  final bool isDutyNext;
  _FiredEvent(this.minute, this.type, this.key, {this.isDutyNext = false});

  @override
  String toString() => '$type@$minute($key${isDutyNext ? ", duty" : ""})';
}

/// Ticks a whole simulated day minute-by-minute through the same decision
/// tree as NotificationService.checkAndNotify (end-of-day -> before-first ->
/// break-ending), including its SharedPreferences-backed dedup ("only notify
/// once per key per day").
List<_FiredEvent> _simulateDay(List<Lesson> lessons, {required int fromMinute, required int toMinute}) {
  final fired = <_FiredEvent>[];
  final firedKeys = <String>{};
  final first = lessons.first;
  final last = lessons.last;

  for (var now = fromMinute; now <= toMinute; now++) {
    // --- end of day ---
    if (now > last.endMinutes) {
      const key = 'end_of_day_SIM';
      if (firedKeys.add(key)) {
        fired.add(_FiredEvent(now, 'end_of_day', key));
      }
      continue;
    }

    // --- before first lesson ---
    if (now < first.startMinutes) {
      final diff = first.startMinutes - now;
      if (diff <= 15 && diff > 0) {
        final key = 'morning_SIM_${first.startString}';
        if (firedKeys.add(key)) {
          fired.add(_FiredEvent(now, 'morning', key));
        }
      }
      continue;
    }

    // --- break ending soon ---
    final nextLesson = findNextLessonDuringBreak(lessons, now);
    if (nextLesson != null) {
      final diff = nextLesson.startMinutes - now;
      if (diff <= _breakEndingMinutes && diff > 0) {
        final key = 'break_ending_SIM_${nextLesson.startString}';
        if (firedKeys.add(key)) {
          fired.add(_FiredEvent(now, 'break_ending', key, isDutyNext: nextLesson.isDuty));
        }
      }
    }
  }
  return fired;
}

void main() {
  group('Duty warning-time selection (scheduleWeekDutyNotifications algorithm)', () {
    // A representative teaching day: three real lessons with a short break
    // (5 min) between the first two and a long break (15 min) between the
    // last two.
    final l1 = _lesson('08:00', '08:45', subject: 'Matematyka');
    final l2 = _lesson('08:50', '09:35', subject: 'Fizyka'); // 5 min after l1
    final l3 = _lesson('09:50', '10:35', subject: 'Chemia'); // 15 min after l2
    final nonDuty = [l1, l2, l3];

    test('duty before the first lesson always gets the long (10 min) warning', () {
      final duty = _lesson('07:30', '08:00', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningLong);
    });

    test('duty starting exactly when the first lesson starts counts as "before first"', () {
      final duty = _lesson('08:00', '08:05', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningLong);
    });

    test('duty inside the short (5 min) break gets the short (5 min) warning', () {
      final duty = _lesson('08:46', '08:49', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningShort);
    });

    test('duty inside the long (15 min) break gets the long (10 min) warning', () {
      final duty = _lesson('09:40', '09:45', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningLong);
    });

    test('a gap of exactly 15 minutes counts as "long" (inclusive boundary)', () {
      // l2 ends 09:35, l3 starts 09:50 -> gap is exactly 15.
      expect(l3.startMinutes - l2.endMinutes, _longBreakMinutes);
      final duty = _lesson('09:36', '09:37', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningLong);
    });

    test('a gap of 14 minutes does NOT count as long', () {
      final tighter = [l1, _lesson('08:50', '09:35'), _lesson('09:49', '10:34')];
      final duty = _lesson('09:36', '09:37', isDuty: true);
      expect(computeDutyWarningMinutes(duty, tighter), _dutyWarningShort);
    });

    test('duty after the last lesson (no trailing gap tracked) falls back to short warning', () {
      final duty = _lesson('10:40', '10:50', isDuty: true);
      expect(computeDutyWarningMinutes(duty, nonDuty), _dutyWarningShort);
    });

    test('no real lessons that day -> every duty gets the long warning', () {
      final duty = _lesson('07:30', '08:00', isDuty: true);
      expect(computeDutyWarningMinutes(duty, []), _dutyWarningLong);
    });
  });

  group('Full-day tick simulation (checkAndNotify algorithm)', () {
    test('a school day with a back-to-back pair and a duty triggers exactly the expected events', () {
      // 08:00-08:45 lesson, 5 min break, 08:50-08:55 duty, back-to-back with
      // a 08:55-09:40 lesson (0 min gap -> must NOT trigger anything).
      final l1 = _lesson('08:00', '08:45', subject: 'Matematyka');
      final duty = _lesson('08:50', '08:55', isDuty: true, subject: 'Dyżur');
      final l2 = _lesson('08:55', '09:40', subject: 'WF');
      final day = [l1, duty, l2];

      final events = _simulateDay(day, fromMinute: 7 * 60, toMinute: 9 * 60 + 45);

      // Expect exactly 3 events: morning heads-up, one break-ending alert
      // for the duty, and end-of-day. The back-to-back l1->duty... wait
      // duty->l2 gap (0 min) must produce NO break-ending event.
      expect(events.length, 3, reason: 'fired events: $events');

      final morning = events.firstWhere((e) => e.type == 'morning');
      expect(morning.minute, l1.startMinutes - 15, reason: 'fires the instant the 15-min window opens');

      final breakEnding = events.where((e) => e.type == 'break_ending').toList();
      expect(breakEnding, hasLength(1), reason: 'the 0-gap duty->l2 transition must not fire');
      expect(breakEnding.single.minute, duty.startMinutes - _breakEndingMinutes);
      expect(breakEnding.single.isDutyNext, isTrue);

      final endOfDay = events.firstWhere((e) => e.type == 'end_of_day');
      expect(endOfDay.minute, l2.endMinutes + 1);
    });

    test('each notification key fires only once per day even though the condition holds for multiple minutes', () {
      final l1 = _lesson('08:00', '08:45');
      final l2 = _lesson('08:50', '09:35'); // 5-minute break -> window is 2 minutes wide
      final events = _simulateDay([l1, l2], fromMinute: 8 * 60 + 40, toMinute: 8 * 60 + 50);

      final breakEndingEvents = events.where((e) => e.type == 'break_ending').toList();
      expect(breakEndingEvents, hasLength(1),
          reason: 'diff<=2 holds for two consecutive minutes (08:48 and 08:49) but must only notify once');
      expect(breakEndingEvents.single.minute, 8 * 60 + 48);
    });

    test('a fully back-to-back day never produces a break-ending notification', () {
      final l1 = _lesson('08:00', '08:45');
      final l2 = _lesson('08:45', '09:30');
      final l3 = _lesson('09:30', '10:15');
      final events = _simulateDay([l1, l2, l3], fromMinute: 7 * 60 + 50, toMinute: 10 * 60 + 20);

      expect(events.where((e) => e.type == 'break_ending'), isEmpty);
    });
  });
}
