import 'package:flutter/material.dart';

class Lesson {
  final TimeOfDay start;
  final TimeOfDay end;
  final String subject;
  final String room;
  final String className;
  final bool isSubstitution;
  final bool isDuty;
  // Whole lesson struck through in the dziennik with no replacement lesson
  // taking its place (e.g. teacher/class absence, cancelled lesson).
  final bool isCancelled;
  // Non-null only when isSubstitution == true — the lesson that was cancelled
  final String? originalSubject;
  final String? originalRoom;
  final String? originalClassName;

  Lesson({
    required this.start,
    required this.end,
    required this.subject,
    required this.room,
    this.className = '',
    this.isSubstitution = false,
    this.isDuty = false,
    this.isCancelled = false,
    this.originalSubject,
    this.originalRoom,
    this.originalClassName,
  });

  factory Lesson.fromJson(Map<String, dynamic> json) {
    final startRaw = (json['start'] ?? '').toString();
    final endRaw = (json['end'] ?? '').toString();

    return Lesson(
      start: _parseTime(startRaw),
      end: _parseTime(endRaw),
      subject: (json['subject'] ?? '').toString(),
      room: (json['room'] ?? '').toString(),
      className: (json['className'] ?? '').toString(),
      isSubstitution: (json['isSubstitution'] as bool?) ?? false,
      isDuty: (json['isDuty'] as bool?) ?? false,
      isCancelled: (json['isCancelled'] as bool?) ?? false,
      originalSubject: json['originalSubject'] as String?,
      originalRoom: json['originalRoom'] as String?,
      originalClassName: json['originalClassName'] as String?,
    );
  }

  static TimeOfDay _parseTime(String time) {
    if (!time.contains(':')) {
      return const TimeOfDay(hour: 0, minute: 0);
    }
    final parts = time.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  String get startString => _formatTime(start);
  String get endString => _formatTime(end);

  int get startMinutes => start.hour * 60 + start.minute;
  int get endMinutes => end.hour * 60 + end.minute;

  Map<String, dynamic> toJson() {
    return {
      'start': startString,
      'end': endString,
      'subject': subject,
      'room': room,
      'className': className,
      'isSubstitution': isSubstitution,
      'isDuty': isDuty,
      'isCancelled': isCancelled,
      if (originalSubject != null) 'originalSubject': originalSubject,
      if (originalRoom != null) 'originalRoom': originalRoom,
      if (originalClassName != null) 'originalClassName': originalClassName,
    };
  }

  bool isNow() {
    final now = TimeOfDay.now();
    return _isAfterOrEqual(now, start) && _isBeforeOrEqual(now, end);
  }

  int minutesUntilEnd() {
    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final endMinutes = end.hour * 60 + end.minute;
    return endMinutes - nowMinutes;
  }

  static bool _isAfterOrEqual(TimeOfDay a, TimeOfDay b) {
    return a.hour > b.hour || (a.hour == b.hour && a.minute >= b.minute);
  }

  static bool _isBeforeOrEqual(TimeOfDay a, TimeOfDay b) {
    return a.hour < b.hour || (a.hour == b.hour && a.minute <= b.minute);
  }

  static String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
