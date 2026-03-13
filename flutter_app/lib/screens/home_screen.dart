import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/services/notification_service.dart';
import 'package:kisiplan/services/timetable_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onLogout,
    required this.timetableService,
  });

  final Future<void> Function() onLogout;
  final TimetableService timetableService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _ScheduleBlock {
  _ScheduleBlock.lesson(Lesson lesson)
      : lesson = lesson,
        isBreak = false,
        previousLesson = null,
        nextLesson = null,
        startMinutes = lesson.startMinutes,
        endMinutes = lesson.endMinutes;

  _ScheduleBlock.breakTime({
    required this.startMinutes,
    required this.endMinutes,
    required this.previousLesson,
    required this.nextLesson,
  })  : isBreak = true,
        lesson = null;

  final Lesson? lesson;
  final bool isBreak;
  final int startMinutes;
  final int endMinutes;
  final Lesson? previousLesson;
  final Lesson? nextLesson;

  String get startString => _formatMinutes(startMinutes);
  String get endString => _formatMinutes(endMinutes);

  int secondsUntilEnd(DateTime now) {
    final nowSeconds = now.hour * 3600 + now.minute * 60 + now.second;
    return endMinutes * 60 - nowSeconds;
  }

  static String _formatMinutes(int totalMinutes) {
    final hours = (totalMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (totalMinutes % 60).toString().padLeft(2, '0');
    return '$hours:$minutes';
  }
}

class _HomeScreenState extends State<HomeScreen> {
  final NotificationService _notificationService = NotificationService();
  List<Lesson> _todayLessons = [];
  Map<String, List<Lesson>> _weekTimetable = {};
  _ScheduleBlock? _currentBlock;
  bool _isLoading = false;
  String? _infoMessage;
  Timer? _ticker;
  DateTime _now = DateTime.now();

  static const _weekdays = ['', 'Poniedziałek', 'Wtorek', 'Środa', 'Czwartek', 'Piątek', 'Sobota', 'Niedziela'];
  static const _dayKeys = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday'];
  static const _dayNames = {
    'monday': 'Poniedziałek',
    'tuesday': 'Wtorek',
    'wednesday': 'Środa',
    'thursday': 'Czwartek',
    'friday': 'Piątek',
  };

  String get _todayKey {
    const keys = ['', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    final wd = _now.weekday;
    return wd >= 1 && wd <= 5 ? keys[wd] : '';
  }

  bool get _schoolDone {
    if (_todayLessons.isEmpty) return false;
    final nowSeconds = _now.hour * 3600 + _now.minute * 60 + _now.second;
    return nowSeconds >= _todayLessons.last.endMinutes * 60;
  }

  List<_ScheduleBlock> _buildTimeline(List<Lesson> lessons) {
    if (lessons.isEmpty) return const [];

    final timeline = <_ScheduleBlock>[];
    for (var index = 0; index < lessons.length; index++) {
      final lesson = lessons[index];
      timeline.add(_ScheduleBlock.lesson(lesson));

      if (index + 1 >= lessons.length) {
        continue;
      }

      final nextLesson = lessons[index + 1];
      if (lesson.endMinutes < nextLesson.startMinutes) {
        timeline.add(
          _ScheduleBlock.breakTime(
            startMinutes: lesson.endMinutes,
            endMinutes: nextLesson.startMinutes,
            previousLesson: lesson,
            nextLesson: nextLesson,
          ),
        );
      }
    }

    return timeline;
  }

  _ScheduleBlock? _resolveCurrent(DateTime now) {
    if (_todayLessons.isEmpty) return null;
    final nowSeconds = now.hour * 3600 + now.minute * 60 + now.second;
    if (nowSeconds >= _todayLessons.last.endMinutes * 60) return null;
    final timeline = _buildTimeline(_todayLessons);
    for (final block in timeline) {
      if (nowSeconds >= block.startMinutes * 60 && nowSeconds < block.endMinutes * 60) {
        return block;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadTimetable();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      setState(() {
        _now = now;
        if (_todayLessons.isNotEmpty) {
          _currentBlock = _resolveCurrent(now);
        }
      });
      if (now.second == 0) {
        _notificationService.checkAndNotify(_todayLessons);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadTimetable() async {
    setState(() {
      _isLoading = true;
      _infoMessage = null;
    });

    final result = await widget.timetableService.getTodayLessons();

    await _notificationService.notifyIfLessonStartsSoon(result.lessons);

    if (!mounted) return;

    setState(() {
      _todayLessons = result.lessons;
      _weekTimetable = result.weekTimetable;
      _currentBlock = _resolveCurrent(DateTime.now());
      _infoMessage = result.warning;
      _isLoading = false;
    });

    // Planowanie powiadomień o dyżurach w tle — nie blokuje UI
    _notificationService.scheduleWeekDutyNotifications(result.weekTimetable);
  }

  Future<void> _handleLogout() async {
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KisiPlan'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTimetable,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final todayTimeline = _buildTimeline(_todayLessons);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader()),
        if (_schoolDone)
          SliverToBoxAdapter(child: _buildEndOfDayMessage())
        else if (_todayLessons.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 32),
              child: Center(
                child: Text('Brak lekcji dzisiaj', style: TextStyle(fontSize: 24)),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildScheduleBlock(todayTimeline[index]),
                childCount: todayTimeline.length,
              ),
            ),
          ),
        SliverToBoxAdapter(child: _buildWeekView()),
        SliverToBoxAdapter(child: _buildAuthorFooter()),
      ],
    );
  }

  Widget _buildAuthorFooter() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, 24 + bottomInset),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Image.asset(
              'assets/kisiciel.jpg',
              width: 48,
              height: 48,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Autor: Marcin Kisielewski',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleBlock(_ScheduleBlock block, {bool compact = false}) {
    if (block.isBreak) {
      return _buildBreakCard(block, compact: compact);
    }

    return _buildLessonCard(block.lesson!, compact: compact);
  }

  Widget _buildBreakCard(_ScheduleBlock block, {bool compact = false}) {
    final isCurrent = identical(block, _currentBlock);

    return Card(
      color: isCurrent ? Colors.green.shade50 : Colors.grey.shade100,
      child: ListTile(
        dense: compact,
        leading: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              block.startString,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: compact ? 12 : 13),
            ),
            Text(
              block.endString,
              style: TextStyle(fontSize: compact ? 10 : 11, color: Colors.grey.shade700),
            ),
          ],
        ),
        title: Row(
          children: [
            Icon(Icons.free_breakfast, size: compact ? 15 : 18, color: Colors.green.shade700),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Przerwa',
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
        subtitle: block.nextLesson == null
            ? null
            : Text(
                'Następnie: ${block.nextLesson!.subject} ${block.nextLesson!.startString}',
                style: TextStyle(fontSize: compact ? 10 : 12),
              ),
        trailing: Text(
          '${block.endMinutes - block.startMinutes} min',
          style: TextStyle(fontSize: compact ? 11 : 13, color: Colors.grey.shade700),
        ),
      ),
    );
  }

  Widget _buildLessonCard(Lesson lesson, {bool compact = false}) {
    final isCurrent = identical(_currentBlock?.lesson, lesson) && !(_currentBlock?.isBreak ?? false);
    Color? cardColor;
    if (isCurrent) {
      cardColor = Colors.blue.shade50;
    } else if (lesson.isDuty) {
      cardColor = Colors.purple.shade50;
    } else if (lesson.isSubstitution) {
      cardColor = Colors.orange.shade50;
    }
    return Card(
      color: cardColor,
      child: ListTile(
        dense: compact,
        leading: Text(
          lesson.startString,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: compact ? 13 : 14),
        ),
        title: lesson.isDuty
            ? Row(
                children: [
                  const Icon(Icons.person_outline, size: 15, color: Colors.purple),
                  const SizedBox(width: 4),
                  Expanded(child: Text(lesson.subject, style: TextStyle(fontSize: compact ? 13 : 14))),
                ],
              )
            : lesson.isSubstitution && lesson.originalSubject != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lesson.originalSubject!,
                    style: TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: Colors.grey,
                      fontSize: compact ? 11 : 13,
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.swap_horiz, size: 15, color: Colors.orange),
                      const SizedBox(width: 4),
                      Expanded(child: Text(lesson.subject, style: TextStyle(fontSize: compact ? 13 : 14))),
                    ],
                  ),
                ],
              )
            : Text(lesson.subject, style: TextStyle(fontSize: compact ? 13 : 14)),
        subtitle: lesson.isSubstitution && lesson.originalClassName != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (lesson.originalClassName!.isNotEmpty)
                    Text(
                      lesson.originalClassName!,
                      style: TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: Colors.grey,
                        fontSize: compact ? 10 : 12,
                      ),
                    ),
                  if (lesson.className.isNotEmpty)
                    Text(lesson.className, style: TextStyle(fontSize: compact ? 10 : 12)),
                ],
              )
            : lesson.className.isNotEmpty
                ? Text(lesson.className, style: TextStyle(fontSize: compact ? 10 : 12, color: Colors.grey))
                : null,
        trailing: lesson.isSubstitution && lesson.originalRoom != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'sala ${lesson.originalRoom}',
                    style: TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: Colors.grey,
                      fontSize: compact ? 11 : 13,
                    ),
                  ),
                  Text('sala ${lesson.room}', style: TextStyle(fontSize: compact ? 12 : 14)),
                ],
              )
            : Text('sala ${lesson.room}', style: TextStyle(fontSize: compact ? 12 : 14)),
      ),
    );
  }

  Widget _buildWeekView() {
    if (_weekTimetable.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Plan na tydzień:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          ..._dayKeys.map((dayKey) {
            final lessons = _weekTimetable[dayKey] ?? [];
            final timeline = _buildTimeline(lessons);
            final isToday = dayKey == _todayKey;

            return Card(
              margin: const EdgeInsets.only(bottom: 4),
              color: isToday ? Colors.blue.shade50 : null,
              child: ExpansionTile(
                key: PageStorageKey(dayKey),
                initiallyExpanded: false,
                leading: isToday
                    ? const Icon(Icons.today, color: Colors.blue)
                    : const Icon(Icons.calendar_today, color: Colors.grey),
                title: Text(
                  _dayNames[dayKey]!,
                  style: TextStyle(
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    color: isToday ? Colors.blue : null,
                  ),
                ),
                trailing: Text(
                  '${timeline.length} pozycji',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                children: timeline.isEmpty
                    ? [
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Brak lekcji', style: TextStyle(color: Colors.grey)),
                        )
                      ]
                    : timeline.map((block) => _buildScheduleBlock(block, compact: true)).toList(),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildClock(),
          if (_infoMessage != null && _infoMessage!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_infoMessage!),
            ),
          ],
          if (!_schoolDone && _currentBlock != null) ...[
            const SizedBox(height: 20),
            Text(
              _currentBlock!.isBreak ? 'Teraz trwa:' : 'Teraz masz:',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              _currentBlock!.isBreak ? 'Przerwa' : _currentBlock!.lesson!.subject,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            if (_currentBlock!.isBreak)
              Text(
                '${_currentBlock!.startString} - ${_currentBlock!.endString}',
                style: const TextStyle(fontSize: 20, color: Colors.grey),
                textAlign: TextAlign.center,
              )
            else
              Text(
                'Sala ${_currentBlock!.lesson!.room}',
                style: const TextStyle(fontSize: 20, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            if (!_currentBlock!.isBreak && _currentBlock!.lesson!.className.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                _currentBlock!.lesson!.className,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
            if (_currentBlock!.isBreak && _currentBlock!.nextLesson != null) ...[
              const SizedBox(height: 2),
              Text(
                [
              'Następnie: ${_currentBlock!.nextLesson!.subject} o ${_currentBlock!.nextLesson!.startString}',
              if (_currentBlock!.nextLesson!.room.isNotEmpty)
                'sala ${_currentBlock!.nextLesson!.room}',
              if (_currentBlock!.nextLesson!.className.isNotEmpty)
                _currentBlock!.nextLesson!.className,
            ].join(' · '),
                style: const TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            _buildProgressBar(),
          ],
          const SizedBox(height: 16),
          if (!_schoolDone && _todayLessons.isNotEmpty)
            const Text('Plan na dziś:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildEndOfDayMessage() {
    final isFriday = _now.weekday == DateTime.friday;
    final message = isFriday
        ? 'Miłego weekendu!\nDo zobaczenia w poniedziałek!'
        : 'Miłego dnia!\nOdpocznij i przygotuj się na dzień jutrzejszy.';
    final icon = isFriday ? '🎉' : '✅';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(icon, style: const TextStyle(fontSize: 64)),
            const SizedBox(height: 24),
            const Text(
              'Lekcje skończone!',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(fontSize: 20, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClock() {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    final s = _now.second.toString().padLeft(2, '0');
    final day = _weekdays[_now.weekday];
    final date = '${_now.day.toString().padLeft(2, '0')}.${_now.month.toString().padLeft(2, '0')}.${_now.year}';

    return Column(
      children: [
        Text('$h:$m:$s', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
        Text('$day, $date', style: const TextStyle(fontSize: 16, color: Colors.grey)),
      ],
    );
  }

  Widget _buildProgressBar() {
    final currentBlock = _currentBlock;
    if (currentBlock == null) {
      return const SizedBox.shrink();
    }

    final secondsLeft = currentBlock.secondsUntilEnd(_now).clamp(0, 99999);
    final totalSeconds = ((currentBlock.endMinutes - currentBlock.startMinutes) * 60).clamp(1, 10800);
    final spentSeconds = (totalSeconds - secondsLeft).clamp(0, totalSeconds);
    final progress = spentSeconds / totalSeconds;
    final minutesLeft = (secondsLeft / 60).ceil();

    return Column(
      children: [
        LinearProgressIndicator(
          value: progress,
          minHeight: 8,
        ),
        const SizedBox(height: 8),
        Text(
          currentBlock.isBreak ? 'Koniec przerwy za $minutesLeft min' : 'Koniec za $minutesLeft min',
          style: const TextStyle(fontSize: 18),
        ),
      ],
    );
  }
}
