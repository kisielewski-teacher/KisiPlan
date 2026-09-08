import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/models/lesson.dart';

// ---------------------------------------------------------------------------
// Mirrors the diffing logic inside lib/services/background_sync_service.dart
// (_sameTimetable / _signature), which decides whether the periodic
// WorkManager task fires "Plan lekcji się zmienił". That class can't run
// under `flutter test` — it drives a real WorkManager/notification platform
// channel — so the pure decision logic is copied verbatim here and exercised
// standalone, the same approach duty_notification_simulation_test.dart uses.
// ---------------------------------------------------------------------------

Set<String> signature(Map<String, List<Lesson>> timetable) {
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

bool sameTimetable(Map<String, List<Lesson>> a, Map<String, List<Lesson>> b) {
  final sigA = signature(a);
  final sigB = signature(b);
  return sigA.length == sigB.length && sigA.containsAll(sigB);
}

Lesson _lesson(
  String start,
  String end, {
  String subject = 'Matematyka',
  String room = '12',
  String className = '3A',
  bool isSubstitution = false,
  bool isDuty = false,
  bool isCancelled = false,
}) {
  return Lesson.fromJson({
    'start': start,
    'end': end,
    'subject': subject,
    'room': room,
    'className': className,
    'isSubstitution': isSubstitution,
    'isDuty': isDuty,
    'isCancelled': isCancelled,
  });
}

void main() {
  group('Plan-changed diffing (background sync notifyPlanChanged trigger)', () {
    test('identical single-day timetables never trigger a notification', () {
      final before = {'monday': [_lesson('08:00', '08:45')]};
      final after = {'monday': [_lesson('08:00', '08:45')]};
      expect(sameTimetable(before, after), isTrue);
    });

    test('a newly-added lesson triggers a notification', () {
      final before = {'monday': [_lesson('08:00', '08:45')]};
      final after = {
        'monday': [_lesson('08:00', '08:45'), _lesson('08:50', '09:35', subject: 'Fizyka')],
      };
      expect(sameTimetable(before, after), isFalse);
    });

    test('a lesson disappearing (e.g. duty removed) triggers a notification', () {
      final before = {
        'monday': [_lesson('08:00', '08:45'), _lesson('08:50', '09:00', isDuty: true)],
      };
      final after = {'monday': [_lesson('08:00', '08:45')]};
      expect(sameTimetable(before, after), isFalse);
    });

    test('a lesson flipping to cancelled triggers a notification', () {
      final before = {'monday': [_lesson('08:00', '08:45')]};
      final after = {'monday': [_lesson('08:00', '08:45', isCancelled: true)]};
      expect(sameTimetable(before, after), isFalse,
          reason: 'the signature includes isCancelled, so a fresh "odwołane" must be detected');
    });

    test('a lesson flipping to a substitution triggers a notification', () {
      final before = {'monday': [_lesson('08:00', '08:45')]};
      final after = {'monday': [_lesson('08:00', '08:45', isSubstitution: true)]};
      expect(sameTimetable(before, after), isFalse,
          reason: 'the signature includes isSubstitution, so a fresh "zastępstwo" must be detected');
    });

    test('a room change alone triggers a notification', () {
      final before = {'monday': [_lesson('08:00', '08:45', room: '12')]};
      final after = {'monday': [_lesson('08:00', '08:45', room: '204')]};
      expect(sameTimetable(before, after), isFalse);
    });

    test('lessons listed in a different order within a day do not falsely trigger', () {
      final l1 = _lesson('08:00', '08:45', subject: 'Matematyka');
      final l2 = _lesson('08:50', '09:35', subject: 'Fizyka');
      final before = {'monday': [l1, l2]};
      final after = {'monday': [l2, l1]};
      expect(sameTimetable(before, after), isTrue,
          reason: 'diffing is a set comparison, so re-sorted lessons must not look like a change');
    });

    test('days processed in a different map iteration order do not falsely trigger', () {
      final before = {
        'monday': [_lesson('08:00', '08:45')],
        'tuesday': [_lesson('09:00', '09:45', subject: 'Chemia')],
      };
      final after = {
        'tuesday': [_lesson('09:00', '09:45', subject: 'Chemia')],
        'monday': [_lesson('08:00', '08:45')],
      };
      expect(sameTimetable(before, after), isTrue);
    });

    test('a change on Friday is still detected even if Monday is untouched', () {
      final before = {
        'monday': [_lesson('08:00', '08:45')],
        'friday': [_lesson('10:00', '10:45', subject: 'WF')],
      };
      final after = {
        'monday': [_lesson('08:00', '08:45')],
        'friday': [_lesson('10:00', '10:45', subject: 'WF', isCancelled: true)],
      };
      expect(sameTimetable(before, after), isFalse);
    });

    test('two empty timetables (e.g. both weeks blank) are considered the same', () {
      expect(sameTimetable({'monday': []}, {'monday': []}), isTrue);
    });
  });
}
