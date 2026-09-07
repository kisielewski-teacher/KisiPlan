import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/models/lesson.dart';

void main() {
  group('Lesson.fromJson / toJson', () {
    test('parses a normal lesson', () {
      final lesson = Lesson.fromJson({
        'start': '08:00',
        'end': '08:45',
        'subject': 'Matematyka',
        'room': '12',
        'className': '3A',
      });

      expect(lesson.start, const TimeOfDay(hour: 8, minute: 0));
      expect(lesson.end, const TimeOfDay(hour: 8, minute: 45));
      expect(lesson.subject, 'Matematyka');
      expect(lesson.room, '12');
      expect(lesson.className, '3A');
      expect(lesson.isSubstitution, isFalse);
      expect(lesson.isDuty, isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final original = Lesson(
        start: const TimeOfDay(hour: 9, minute: 50),
        end: const TimeOfDay(hour: 10, minute: 35),
        subject: 'Fizyka',
        room: '7',
        className: '2B',
        isSubstitution: true,
        originalSubject: 'WF',
        originalRoom: 'Sala gimn.',
        originalClassName: '2B',
      );

      final roundTripped = Lesson.fromJson(original.toJson());

      expect(roundTripped.startString, original.startString);
      expect(roundTripped.endString, original.endString);
      expect(roundTripped.subject, original.subject);
      expect(roundTripped.isSubstitution, isTrue);
      expect(roundTripped.originalSubject, 'WF');
      expect(roundTripped.originalRoom, 'Sala gimn.');
    });

    test('missing/empty time string falls back to 00:00 instead of throwing', () {
      final lesson = Lesson.fromJson({
        'subject': 'Nieznana',
        'room': '',
      });

      expect(lesson.start, const TimeOfDay(hour: 0, minute: 0));
      expect(lesson.end, const TimeOfDay(hour: 0, minute: 0));
      expect(lesson.subject, 'Nieznana');
    });

    test('missing optional fields default to empty/false rather than null', () {
      final lesson = Lesson.fromJson({'start': '10:00', 'end': '10:45'});

      expect(lesson.subject, '');
      expect(lesson.room, '');
      expect(lesson.className, '');
      expect(lesson.isDuty, isFalse);
      expect(lesson.isCancelled, isFalse);
      expect(lesson.originalSubject, isNull);
    });

    test('a cancelled lesson (struck through with no replacement) round-trips isCancelled', () {
      final lesson = Lesson.fromJson({
        'start': '08:00',
        'end': '08:45',
        'subject': 'Matematyka',
        'room': '12',
        'className': '3A',
        'isCancelled': true,
      });

      expect(lesson.isCancelled, isTrue);
      expect(lesson.isSubstitution, isFalse);
      expect(Lesson.fromJson(lesson.toJson()).isCancelled, isTrue);
    });

    test('toJson omits substitution fields when null', () {
      final lesson = Lesson(
        start: const TimeOfDay(hour: 8, minute: 0),
        end: const TimeOfDay(hour: 8, minute: 45),
        subject: 'Chemia',
        room: '3',
      );

      final json = lesson.toJson();

      expect(json.containsKey('originalSubject'), isFalse);
      expect(json.containsKey('originalRoom'), isFalse);
      expect(json.containsKey('originalClassName'), isFalse);
    });
  });

  group('Lesson time arithmetic', () {
    test('startMinutes/endMinutes compute correct offsets since midnight', () {
      final lesson = Lesson(
        start: const TimeOfDay(hour: 13, minute: 30),
        end: const TimeOfDay(hour: 14, minute: 15),
        subject: 'Historia',
        room: '5',
      );

      expect(lesson.startMinutes, 13 * 60 + 30);
      expect(lesson.endMinutes, 14 * 60 + 15);
      expect(lesson.endMinutes - lesson.startMinutes, 45);
    });

    test('startString/endString pad single-digit hours and minutes', () {
      final lesson = Lesson(
        start: const TimeOfDay(hour: 8, minute: 5),
        end: const TimeOfDay(hour: 9, minute: 0),
        subject: 'Angielski',
        room: '1',
      );

      expect(lesson.startString, '08:05');
      expect(lesson.endString, '09:00');
    });

    test('midnight-spanning edge case is represented, even if not clamped', () {
      // The model does not clamp hours to 0-23; garbage-in/garbage-out is
      // expected from upstream parsing, but the arithmetic must stay linear.
      final lesson = Lesson(
        start: const TimeOfDay(hour: 23, minute: 50),
        end: const TimeOfDay(hour: 23, minute: 55),
        subject: 'Nocna zmiana',
        room: '0',
      );

      expect(lesson.endMinutes - lesson.startMinutes, 5);
    });
  });
}
