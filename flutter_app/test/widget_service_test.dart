import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/services/widget_service.dart';

Lesson _lesson(String start, String end, {String subject = 'Lekcja'}) {
  return Lesson.fromJson({'start': start, 'end': end, 'subject': subject, 'room': '1'});
}

void main() {
  group('findCurrentLesson / findNextLesson', () {
    final l1 = _lesson('08:00', '08:45', subject: 'Matematyka');
    final l2 = _lesson('08:50', '09:35', subject: 'Fizyka');
    final l3 = _lesson('09:50', '10:35', subject: 'Chemia');
    final day = [l1, l2, l3];

    test('returns the lesson in progress when now falls inside its range', () {
      expect(findCurrentLesson(day, 8 * 60 + 30), same(l1));
      expect(findCurrentLesson(day, 9 * 60), same(l2));
    });

    test('returns null during a break, even though a lesson is "next"', () {
      expect(findCurrentLesson(day, 8 * 60 + 47), isNull);
    });

    test('findNextLesson finds the soonest lesson strictly after now', () {
      expect(findNextLesson(day, 8 * 60 + 47), same(l2));
      expect(findNextLesson(day, 7 * 60), same(l1));
    });

    test('findNextLesson returns null after the last lesson has started', () {
      expect(findNextLesson(day, 9 * 60 + 51), isNull);
    });

    test('an empty day has neither a current nor a next lesson', () {
      expect(findCurrentLesson(const [], 8 * 60), isNull);
      expect(findNextLesson(const [], 8 * 60), isNull);
    });
  });
}
