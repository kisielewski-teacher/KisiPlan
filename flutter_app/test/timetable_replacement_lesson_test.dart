import 'package:flutter_test/flutter_test.dart';
import 'package:plan_mechanika/services/timetable_service.dart';

// A cell whose original lesson carries "nieobecność klasy" must still keep
// the real replacement lesson ("zastępstwo") that covers the same slot.
void main() {
  test('nieobecność klasy keeps the replacement zastępstwo lesson', () {
    const html = '''
<table><tr>
<td data-date="2026-10-06" data-time_from="11:45" data-time_to="12:30">
  <div class="text"><s><b>Projektowanie</b>- 4cT5 gr. 2 s. 405</s></div>
  <div class="text"><b>Fizyka</b>- 1bT5 T4 Marcin Kisielewski s. 308</div>
  <div class="center plan-lekcji-info">nieobecność klasy 4cT5 T4</div>
  <div class="center plan-lekcji-info">zastępstwo</div>
</td></tr></table>''';
    final lessons = TimetableService().parseHtmlTimetableForTest(html)['tuesday']!;

    expect(lessons.length, 2);
    expect(lessons.where((l) => l.isCancelled).single.subject, 'Projektowanie');
    final sub = lessons.singleWhere((l) => !l.isCancelled);
    expect(sub.subject, 'Fizyka');
    expect(sub.room, '308');
    expect(sub.isSubstitution, isTrue);
  });
}
