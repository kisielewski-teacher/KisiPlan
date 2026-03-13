import 'package:kisiplan/models/lesson.dart';

class LoadResult {
  final List<Lesson> lessons;
  final Map<String, List<Lesson>> weekTimetable;
  final bool fromCache;
  final String? warning;

  const LoadResult({
    required this.lessons,
    this.weekTimetable = const {},
    this.fromCache = false,
    this.warning,
  });
}
