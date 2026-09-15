import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
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

  group('TimetableService.isEntirelyStruckThrough', () {
    // Regression: a "przesunięcie" pair's VACATED slot (real markup pulled
    // from the live dziennik, 2026-09-15) renders as a single div.text whose
    // entire content is wrapped in one <s> — the lesson used to happen here
    // but now happens in a completely different cell (different time). That
    // cell was rendering with no strikethrough at all before this fix,
    // because the parser only recognized two separate div.text elements
    // (original + replacement) in the SAME cell as a "there's an original to
    // show struck through" signal — a pattern that, empirically, never
    // actually occurs for this real dziennik markup.
    test('true when the div\'s only child is a single <s> wrapping everything', () {
      final doc = html_parser.parse(
        '<div class="text"><s><b>Fizyka</b><br>- 2eBsp&nbsp;BS4&nbsp;&nbsp;s.&nbsp;302</s></div>',
      );
      final div = doc.querySelector('div.text')!;

      expect(TimetableService.isEntirelyStruckThrough(div), isTrue);
    });

    test('false for the destination cell: same lesson, not struck through', () {
      final doc = html_parser.parse(
        '<div class="text"><b>Fizyka</b><br>- 2eBsp&nbsp;BS4 Marcin Kisielewski&nbsp;&nbsp;s.&nbsp;302</div>',
      );
      final div = doc.querySelector('div.text')!;

      expect(TimetableService.isEntirelyStruckThrough(div), isFalse);
    });

    test('false when only part of the div is struck through (two separate pieces)', () {
      final doc = html_parser.parse(
        '<div class="text"><s>Matematyka - 3A</s> <b>Fizyka</b> - 3A s. 12</div>',
      );
      final div = doc.querySelector('div.text')!;

      expect(TimetableService.isEntirelyStruckThrough(div), isFalse);
    });

    test('false for an empty div', () {
      final doc = html_parser.parse('<div class="text"></div>');
      final div = doc.querySelector('div.text')!;

      expect(TimetableService.isEntirelyStruckThrough(div), isFalse);
    });
  });
}
