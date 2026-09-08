import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/services/notification_service.dart';
import 'package:kisiplan/services/timetable_service.dart';
import 'package:kisiplan/services/update_service.dart';
import 'package:kisiplan/services/widget_service.dart';
import 'package:url_launcher/url_launcher.dart';

// Adres, na który trafiają pomysły użytkowników zgłoszone z aplikacji.
const _feedbackEmail = 'oxykisiel@gmail.com';

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
      : lesson = lesson, // ignore: prefer_initializing_formals
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
  final UpdateService _updateService = UpdateService();
  final WidgetService _widgetService = WidgetService();
  // null = not checked yet this session, true = update pending, false = up to date.
  bool? _updateAvailable;
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

  bool get _currentIsFreeWindow =>
      _currentBlock != null && !_currentBlock!.isBreak && (_currentBlock!.lesson?.isCancelled ?? false);

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
    _refreshUpdateIndicator();
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
        _widgetService.updateFromTodayLessons(_todayLessons);
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
    _widgetService.updateFromTodayLessons(result.lessons);
  }

  Future<void> _handleLogout() async {
    await widget.onLogout();
  }

  /// Colors the update icon from cache immediately, then — at most once
  /// every few days (see UpdateService.checkForUpdateThrottled) — does a
  /// real check, refreshes the icon and, if something new turned up,
  /// reminds the user with the update dialog.
  Future<void> _refreshUpdateIndicator() async {
    final cached = await _updateService.cachedUpdate();
    if (mounted) setState(() => _updateAvailable = cached != null);

    final result = await _updateService.checkForUpdateThrottled();
    if (!mounted) return;
    setState(() => _updateAvailable = result != null);
    if (result != null) {
      _showUpdateDialog(result);
    }
  }

  Future<void> _checkForUpdateManually() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final update = await _updateService.checkForUpdate();
      if (!mounted) return;
      setState(() => _updateAvailable = update != null);
      if (update == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Masz już najnowszą wersję aplikacji.')),
        );
        return;
      }
      _showUpdateDialog(update);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Nie udało się sprawdzić aktualizacji: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  void _showUpdateDialog(UpdateInfo update) {
    showDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(update: update, updateService: _updateService),
    );
  }

  Future<void> _openIdeaDialog() async {
    final controller = TextEditingController();
    final idea = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Prześlij pomysł'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Opisz swój pomysł na aplikację...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Wyślij'),
          ),
        ],
      ),
    );

    if (idea == null || idea.isEmpty) return;
    await _sendIdea(idea);
  }

  Future<void> _sendIdea(String idea) async {
    final uri = Uri(
      scheme: 'mailto',
      path: _feedbackEmail,
      query: 'subject=${Uri.encodeComponent('Pomysł na Plan Mechanika')}'
          '&body=${Uri.encodeComponent(idea)}',
    );

    final launched = await launchUrl(uri);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          launched
              ? 'Otwarto aplikację pocztową z Twoim pomysłem.'
              : 'Nie udało się otworzyć aplikacji pocztowej.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Plan Mechanika',
          style: TextStyle(fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.system_update,
              color: _updateAvailable == true
                  ? Colors.redAccent
                  : _updateAvailable == false
                      ? Colors.greenAccent
                      : null,
            ),
            tooltip: _updateAvailable == true
                ? 'Dostępna jest nowa wersja'
                : 'Sprawdź aktualizacje',
            onPressed: _checkForUpdateManually,
          ),
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: 'Prześlij pomysł',
            onPressed: _openIdeaDialog,
          ),
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
      child: const Center(
        child: Text(
          'Autor: Marcin Kisielewski',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
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
    } else if (lesson.isCancelled) {
      cardColor = Colors.grey.shade200;
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
                  Expanded(
                    child: Text(
                      lesson.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? 13 : 14),
                    ),
                  ),
                ],
              )
            : lesson.isCancelled
            ? Row(
                children: [
                  const Icon(Icons.event_busy, size: 15, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      lesson.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: Colors.grey,
                        fontSize: compact ? 13 : 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildTag('Okienko', Colors.blueGrey, compact: compact),
                ],
              )
            : lesson.isSubstitution && lesson.originalSubject != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lesson.originalSubject!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                      Expanded(
                        child: Text(
                          lesson.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: compact ? 13 : 14),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _buildTag('Zastępstwo', Colors.green, compact: compact),
                    ],
                  ),
                ],
              )
            : Text(
                lesson.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: compact ? 13 : 14),
              ),
        subtitle: lesson.isCancelled
            ? (lesson.className.isNotEmpty
                ? Text(
                    lesson.className,
                    style: TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: Colors.grey,
                      fontSize: compact ? 10 : 12,
                    ),
                  )
                : null)
            : lesson.isSubstitution && lesson.originalClassName != null
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
        trailing: lesson.isDuty
            ? _roomTrailing(lesson.room, compact: compact)
            : lesson.isCancelled
            ? _roomTrailing('sala ${lesson.room}', compact: compact, strikeThrough: true)
            : lesson.isSubstitution && lesson.originalRoom != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _roomTrailing(
                    'sala ${lesson.originalRoom}',
                    compact: compact,
                    strikeThrough: true,
                    fontSize: compact ? 11 : 13,
                  ),
                  _roomTrailing('sala ${lesson.room}', compact: compact),
                ],
              )
            : _roomTrailing('sala ${lesson.room}', compact: compact),
      ),
    );
  }

  /// A small colored badge, styled after the "zastępstwo"/"nieobecność"
  /// annotations shown next to lessons in Librus.
  Widget _buildTag(String label, MaterialColor color, {bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade700,
          fontWeight: FontWeight.w600,
          fontSize: compact ? 9 : 10,
        ),
      ),
    );
  }

  /// A trailing room/location label constrained to a fixed max width so a
  /// long string (e.g. a duty location like a street name) can't squeeze the
  /// title column down to almost nothing — it wraps/truncates instead.
  Widget _roomTrailing(
    String text, {
    bool compact = false,
    bool strikeThrough = false,
    double? fontSize,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: Text(
        text,
        textAlign: TextAlign.end,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          decoration: strikeThrough ? TextDecoration.lineThrough : null,
          color: strikeThrough ? Colors.grey : null,
          fontSize: fontSize ?? (compact ? 12 : 14),
        ),
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
              _currentBlock!.isBreak || _currentIsFreeWindow ? 'Teraz trwa:' : 'Teraz masz:',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              _currentBlock!.isBreak
                  ? 'Przerwa'
                  : _currentIsFreeWindow
                      ? 'Okienko'
                      : _currentBlock!.lesson!.subject,
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
            else if (_currentIsFreeWindow)
              Text(
                'Odwołano: ${_currentBlock!.lesson!.subject}'
                '${_currentBlock!.lesson!.className.isNotEmpty ? ' (${_currentBlock!.lesson!.className})' : ''}',
                style: const TextStyle(fontSize: 18, color: Colors.grey),
                textAlign: TextAlign.center,
              )
            else
              Text(
                'Sala ${_currentBlock!.lesson!.room}',
                style: const TextStyle(fontSize: 20, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            if (!_currentBlock!.isBreak && !_currentIsFreeWindow && _currentBlock!.lesson!.className.isNotEmpty) ...[
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

enum _UpdateStage { prompt, downloading, needsPermission, readyToInstall, error }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.update, required this.updateService});

  final UpdateInfo update;
  final UpdateService updateService;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdateStage _stage = _UpdateStage.prompt;
  double _progress = 0;
  String? _errorMessage;
  File? _downloadedFile;

  Future<void> _startDownload() async {
    setState(() {
      _stage = _UpdateStage.downloading;
      _progress = 0;
      _errorMessage = null;
    });

    try {
      final file = await widget.updateService.download(
        widget.update.downloadUrl,
        (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      _downloadedFile = file;
      await _proceedToInstall();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _UpdateStage.error;
        _errorMessage = 'Nie udało się pobrać aktualizacji: $e';
      });
    }
  }

  Future<void> _proceedToInstall() async {
    final canInstall = await widget.updateService.canRequestInstalls();
    if (!mounted) return;
    if (!canInstall) {
      setState(() => _stage = _UpdateStage.needsPermission);
      return;
    }
    setState(() => _stage = _UpdateStage.readyToInstall);
    await widget.updateService.installApk(_downloadedFile!.path);
  }

  Future<void> _openSettingsThenRetry() async {
    await widget.updateService.openInstallPermissionSettings();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nowa wersja dostępna'),
      content: SingleChildScrollView(child: _buildContent()),
      actions: _buildActions(),
    );
  }

  Widget _buildContent() {
    switch (_stage) {
      case _UpdateStage.prompt:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Dostępna jest wersja ${widget.update.version}.'),
            if (widget.update.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(widget.update.releaseNotes),
            ],
          ],
        );
      case _UpdateStage.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text('Pobieranie... ${(_progress * 100).toStringAsFixed(0)}%'),
          ],
        );
      case _UpdateStage.needsPermission:
        return const Text(
          'Aby zainstalować aktualizację, zezwól aplikacji na instalowanie '
          'nieznanych aplikacji w ustawieniach systemowych, a następnie wróć tutaj.',
        );
      case _UpdateStage.readyToInstall:
        return const Text('Otwieranie instalatora...');
      case _UpdateStage.error:
        return Text(_errorMessage ?? 'Wystąpił nieznany błąd.');
    }
  }

  List<Widget> _buildActions() {
    switch (_stage) {
      case _UpdateStage.prompt:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Później'),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: const Text('Pobierz i zainstaluj'),
          ),
        ];
      case _UpdateStage.downloading:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
        ];
      case _UpdateStage.needsPermission:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zamknij'),
          ),
          TextButton(
            onPressed: _openSettingsThenRetry,
            child: const Text('Otwórz ustawienia'),
          ),
          FilledButton(
            onPressed: _proceedToInstall,
            child: const Text('Kontynuuj'),
          ),
        ];
      case _UpdateStage.readyToInstall:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zamknij'),
          ),
        ];
      case _UpdateStage.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zamknij'),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: const Text('Spróbuj ponownie'),
          ),
        ];
    }
  }
}
