import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kisiplan/models/lesson.dart';

class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _channelId = 'lesson_alerts';
  static const _channelName = 'Powiadomienia o lekcjach';

  static const _idBreakEnding = 1003;
  static const _idEndOfDay = 1004;
  static const _idMorning = 1005;
  static const _idDuty = 1006;

  // Ile minut przed lekcją wysłać powiadomienie o końcu przerwy
  static const _breakEndingMinutes = 3;

  static const _androidDetails = AndroidNotificationDetails(
    _channelId,
    _channelName,
    channelDescription: 'Powiadomienia o lekcjach i przerwach',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _notifDetails = NotificationDetails(
    android: _androidDetails,
    iOS: DarwinNotificationDetails(),
  );

  int _notificationIdFor(String key, int fallbackBase) {
    return fallbackBase + (key.hashCode & 0x3fffffff);
  }

  String _formatDutyBody(Lesson duty) {
    final location = duty.room.trim();
    final locationText = location.isEmpty ? 'Sprawdź miejsce dyżuru w planie.' : 'Idź na dyżur: $location.';
    return '$locationText Dyżur trwa ${duty.startString}-${duty.endString}.';
  }

  Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);

    await _plugin.initialize(settings);

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  /// Sprawdza aktualny stan i wysyła odpowiednie powiadomienie.
  /// Wywoływana co minutę z timera.
  Future<void> checkAndNotify(List<Lesson> lessons) async {
    if (lessons.isEmpty) return;
    if (!_initialized) {
      await init();
    }

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final dateKey = '${now.year}-${now.month}-${now.day}';
    final prefs = await SharedPreferences.getInstance();

    final firstLesson = lessons.first;
    final lastLesson = lessons.last;

    // --- KONIEC DNIA ---
    if (nowMinutes > lastLesson.endMinutes) {
      final key = 'end_of_day_$dateKey';
      if (prefs.getString(key) == null) {
        final isFriday = now.weekday == DateTime.friday;
        final body = isFriday
            ? 'Miłego weekendu! Do zobaczenia w poniedziałek!'
            : 'Miłego dnia! Odpocznij i przygotuj się na jutro.';
        await _plugin.show(
          _idEndOfDay,
          'Lekcje skończone na dziś!',
          body,
          _notifDetails,
        );
        await prefs.setString(key, '1');
      }
      return;
    }

    // --- RANO: przed pierwszą lekcją ---
    if (nowMinutes < firstLesson.startMinutes) {
      final diff = firstLesson.startMinutes - nowMinutes;
      if (diff <= 15 && diff > 0) {
        final key = 'morning_${dateKey}_${firstLesson.startString}';
        if (prefs.getString(key) == null) {
          await _plugin.show(
            _idMorning,
            'Dzień dobry!',
            'Niedługo zaczynają się lekcje o ${firstLesson.startString}. '
                'Pierwsza: ${firstLesson.subject} w sali ${firstLesson.room}.',
            _notifDetails,
          );
          await prefs.setString(key, '1');
        }
      }
      return;
    }

    for (final lesson in lessons.where((lesson) => lesson.isDuty)) {
      if (nowMinutes != lesson.startMinutes) {
        continue;
      }

      final key = 'duty_${dateKey}_${lesson.startString}_${lesson.room}_${lesson.subject}';
      if (prefs.getString(key) != null) {
        continue;
      }

      await _plugin.show(
        _notificationIdFor(key, _idDuty),
        'Zaczyna się dyżur',
        _formatDutyBody(lesson),
        _notifDetails,
      );
      await prefs.setString(key, '1');
    }

    // --- PRZED KAŻDĄ LEKCJĄ (koniec przerwy) ---
    // Szukamy następnej lekcji gdy jesteśmy w przerwie
    Lesson? nextLesson;
    for (int i = 0; i < lessons.length; i++) {
      final l = lessons[i];
      // Jesteśmy w przerwie między l a l+1
      if (nowMinutes >= l.endMinutes &&
          i + 1 < lessons.length &&
          nowMinutes < lessons[i + 1].startMinutes) {
        nextLesson = lessons[i + 1];
        break;
      }
    }

    if (nextLesson != null) {
      final diff = nextLesson.startMinutes - nowMinutes;
      if (diff <= _breakEndingMinutes && diff > 0) {
        final key = 'break_ending_${dateKey}_${nextLesson.startString}';
        if (prefs.getString(key) == null) {
          await _plugin.show(
            _notificationIdFor(key, _idBreakEnding),
            'Przerwa za $diff min się kończy!',
            'Następna lekcja: ${nextLesson.subject} w sali ${nextLesson.room} (${nextLesson.startString}).',
            _notifDetails,
          );
          await prefs.setString(key, '1');
        }
      }
    }
  }

  /// Powiadomienie przy pierwszym załadowaniu planu (gdy lekcja za chwilę).
  Future<void> notifyIfLessonStartsSoon(List<Lesson> lessons) async {
    if (lessons.isEmpty) return;
    if (!_initialized) {
      await init();
    }

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    Lesson? nextLesson;
    int minDiff = 9999;

    for (final lesson in lessons) {
      final diff = lesson.startMinutes - nowMinutes;
      if (diff > 0 && diff < minDiff) {
        minDiff = diff;
        nextLesson = lesson;
      }
    }

    if (nextLesson == null || minDiff > _breakEndingMinutes) return;

    final todayKey =
        '${now.year}-${now.month}-${now.day}-${nextLesson.subject}-${nextLesson.startString}';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('last_notification_key') == todayKey) return;

    await _plugin.show(
      _notificationIdFor(todayKey, _idBreakEnding),
      nextLesson.isDuty ? 'Dyżur za $minDiff min' : 'Przerwa za $minDiff min się kończy!',
      nextLesson.isDuty
          ? _formatDutyBody(nextLesson)
          : 'Następna lekcja: ${nextLesson.subject} w sali ${nextLesson.room} (${nextLesson.startString}).',
      _notifDetails,
    );

    await prefs.setString('last_notification_key', todayKey);
  }
}
