import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/services/timetable_service.dart';

// Regression test for a mismatch between the dziennik (Librus) and the app:
// a lesson tagged "przesunięcie" in Librus (the teacher's own lesson shifted
// to a different slot) was showing up in the app tagged "Zastępstwo" (a
// colleague covering the class) instead. TimetableService.classifyChangeBadge
// is the pure decision function behind that badge, extracted so it can be
// exercised here without going through the full HTML parser.
void main() {
  group('TimetableService.classifyChangeBadge', () {
    test('"przesunięcie" badge with a replacement lesson is classified as moved, not substituted', () {
      final result = TimetableService.classifyChangeBadge('przesunięcie', hasReplacementLesson: true);

      expect(result.isMoved, isTrue);
      expect(result.isSubstitution, isFalse);
      expect(result.isCancelled, isFalse);
    });

    test('"zastępstwo" badge with a replacement lesson is classified as a real substitution', () {
      final result = TimetableService.classifyChangeBadge('Zastępstwo', hasReplacementLesson: true);

      expect(result.isSubstitution, isTrue);
      expect(result.isMoved, isFalse);
      expect(result.isCancelled, isFalse);
    });

    test('"przesunięcie" badge with no replacement lesson shown is still classified as moved', () {
      final result = TimetableService.classifyChangeBadge('przesunięcie', hasReplacementLesson: false);

      expect(result.isMoved, isTrue);
      expect(result.isSubstitution, isFalse);
      expect(result.isCancelled, isFalse);
    });

    test('ASCII fallback spellings ("zastepstwo"/"przesuniecie") are recognized too', () {
      final substitution = TimetableService.classifyChangeBadge('zastepstwo', hasReplacementLesson: true);
      final moved = TimetableService.classifyChangeBadge('przesuniecie', hasReplacementLesson: true);

      expect(substitution.isSubstitution, isTrue);
      expect(moved.isMoved, isTrue);
    });

    test('no badge and a replacement lesson shown falls back to substitution (legacy behaviour)', () {
      final result = TimetableService.classifyChangeBadge('', hasReplacementLesson: true);

      expect(result.isSubstitution, isTrue);
      expect(result.isMoved, isFalse);
      expect(result.isCancelled, isFalse);
    });

    test('no badge and no replacement lesson shown is a plain cancellation', () {
      final result = TimetableService.classifyChangeBadge('', hasReplacementLesson: false);

      expect(result.isCancelled, isTrue);
      expect(result.isSubstitution, isFalse);
      expect(result.isMoved, isFalse);
    });
  });

  group('TimetableService.isOkienkoPlaceholder', () {
    // Regression: when a moved-away lesson's original slot is struck through
    // in the dziennik with "Okienko" as the "replacement" text, that's not a
    // real substituted/moved-in lesson — it's Librus spelling out that the
    // slot is now free time. The struck-through original should be shown
    // with the "Okienko" tag instead of being treated as a substitution.
    test('recognizes "Okienko" regardless of casing/whitespace', () {
      expect(TimetableService.isOkienkoPlaceholder('Okienko'), isTrue);
      expect(TimetableService.isOkienkoPlaceholder('okienko'), isTrue);
      expect(TimetableService.isOkienkoPlaceholder('  Okienko  '), isTrue);
      expect(TimetableService.isOkienkoPlaceholder('OKIENKO'), isTrue);
    });

    test('does not match a real subject that merely contains the word', () {
      expect(TimetableService.isOkienkoPlaceholder('Fizyka - 2eBsp BS4 s.302'), isFalse);
      expect(TimetableService.isOkienkoPlaceholder(''), isFalse);
    });
  });
}
