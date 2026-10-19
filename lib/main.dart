import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:image_picker/image_picker.dart';

import 'background_config.dart';
import 'notification_service.dart';
import 'dnd_service.dart';
import 'weather_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN', null);
  await NotificationService.init();
  runApp(const MyApp());
}

String fmtTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String timeToStr(TimeOfDay t) => fmtTime(t);

TimeOfDay strToTime(String s,
    {TimeOfDay fallback = const TimeOfDay(hour: 8, minute: 0)}) {
  try {
    final p = s.split(':');
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  } catch (_) {
    return fallback;
  }
}

bool isCrossMidnight(TimeOfDay start, TimeOfDay end) =>
    (end.hour * 60 + end.minute) <= (start.hour * 60 + start.minute);

double hoursBetween(TimeOfDay start, TimeOfDay end) {
  var m = (end.hour * 60 + end.minute) - (start.hour * 60 + start.minute);
  if (m <= 0) m += 24 * 60;
  return m / 60.0;
}

String rangeText(TimeOfDay start, TimeOfDay end) {
  final cross = isCrossMidnight(start, end);
  final h = hoursBetween(start, end);
  final hStr =
      h == h.roundToDouble() ? h.toStringAsFixed(0) : h.toStringAsFixed(1);
  return '${fmtTime(start)} - ${cross ? '次日' : ''}${fmtTime(end)}（${hStr}小时）';
}

class ShiftConfig {
  TimeOfDay dayStart;
  TimeOfDay dayEnd;
  TimeOfDay nightStart;
  TimeOfDay nightEnd;
  ShiftConfig({
    this.dayStart = const TimeOfDay(hour: 8, minute: 0),
    this.dayEnd = const TimeOfDay(hour: 20, minute: 0),
    this.nightStart = const TimeOfDay(hour: 20, minute: 0),
    this.nightEnd = const TimeOfDay(hour: 8, minute: 0),
  });
  double get dayHours => hoursBetween(dayStart, dayEnd);
  double get nightHours => hoursBetween(nightStart, nightEnd);
}

class AlarmConfig {
  bool enabled;
  int minutesBefore;
  AlarmConfig({this.enabled = true, this.minutesBefore = 30});
}

class DndConfig {
  bool enabled;
  TimeOfDay start;
  TimeOfDay end;
  bool autoApply;
  DndConfig({
    this.enabled = false,
    this.start = const TimeOfDay(hour: 22, minute: 0),
    this.end = const TimeOfDay(hour: 7, minute: 0),
    this.autoApply = true,
  });
}

class AppSettings {
  int group;
  DateTime cycleStart;
  ShiftConfig shift;
  AlarmConfig alarm;
  DndConfig dnd;
  BackgroundConfig bg;
  AppSettings({
    this.group = 0,
    required this.cycleStart,
    ShiftConfig? shift,
    AlarmConfig? alarm,
    DndConfig? dnd,
    BackgroundConfig? bg,
  })  : shift = shift ?? ShiftConfig(),
        alarm = alarm ?? AlarmConfig(),
        dnd = dnd ?? DndConfig(),
        bg = bg ?? BackgroundConfig();
}

enum ShiftType { day, night, rest }

extension ShiftTypeX on ShiftType {
  String get label => switch (this) {
        ShiftType.day => '白班',
        ShiftType.night => '夜班',
        ShiftType.rest => '休息',
      };

  Color get color => switch (this) {
        ShiftType.day => Colors.orange,
        ShiftType.night => Colors.indigo,
        ShiftType.rest => Colors.green,
      };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '上12休24排班',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A7DFF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
          iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  int _group = 0;
  DateTime _cycleStart = DateTime.now();
  ShiftConfig _shift = ShiftConfig();
  AlarmConfig _alarm = AlarmConfig();
  DndConfig _dnd = DndConfig();
  BackgroundConfig _bg = BackgroundConfig();
  Map<String, String> _overrides = {};
  Map<String, dynamic> _weather = {};
  SharedPreferences? _prefs;
  Timer? _dndTimer;

  static const _groups = ['甲组', '乙组', '丙组'];
  static const _cycle = [ShiftType.day, ShiftType.night, ShiftType.rest];

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _load();
  }

  @override
  void dispose() {
    _dndTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    setState(() {
      _group = prefs.getInt('group') ?? 0;
      final startStr = prefs.getString('cycleStart');
      if (startStr != null) _cycleStart = DateTime.parse(startStr);
      _shift = ShiftConfig(
        dayStart: strToTime(prefs.getString('dayStart') ?? '08:00'),
        dayEnd: strToTime(prefs.getString('dayEnd') ?? '20:00'),
        nightStart: strToTime(prefs.getString('nightStart') ?? '20:00'),
        nightEnd: strToTime(prefs.getString('nightEnd') ?? '08:00'),
      );
      _alarm = AlarmConfig(
        enabled: prefs.getBool('alarmEnabled') ?? true,
        minutesBefore: prefs.getInt('alarmMinutes') ?? 30,
      );
      _dnd = DndConfig(
        enabled: prefs.getBool('dndEnabled') ?? false,
        start: strToTime(prefs.getString('dndStart') ?? '22:00'),
        end: strToTime(prefs.getString('dndEnd') ?? '07:00'),
        autoApply: prefs.getBool('dndAuto') ?? true,
      );
      _bg = BackgroundConfig.fromMap({
        'type': prefs.getString('bgType'),
        'color': prefs.getString('bgColor'),
        'grad1': prefs.getString('bgGrad1'),
        'grad2': prefs.getString('bgGrad2'),
        'image': prefs.getString('bgImage'),
        'opacity': prefs.getString('bgOpacity'),
        'blur': prefs.getString('bgBlur'),
      });
      final raw = prefs.getStringList('overrides') ?? [];
      _overrides = {
        for (final e in raw)
          if (e.contains('|')) e.split('|')[0]: e.split('|')[1]
      };
    });
    _rescheduleAlarms();
    _startDndWatcher();
    _loadWeather();
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setInt('group', _group);
    await prefs.setString('cycleStart', _cycleStart.toIso8601String());
    await prefs.setString('dayStart', timeToStr(_shift.dayStart));
    await prefs.setString('dayEnd', timeToStr(_shift.dayEnd));
    await prefs.setString('nightStart', timeToStr(_shift.nightStart));
    await prefs.setString('nightEnd', timeToStr(_shift.nightEnd));
    await prefs.setBool('alarmEnabled', _alarm.enabled);
    await prefs.setInt('alarmMinutes', _alarm.minutesBefore);
    await prefs.setBool('dndEnabled', _dnd.enabled);
    await prefs.setString('dndStart', timeToStr(_dnd.start));
    await prefs.setString('dndEnd', timeToStr(_dnd.end));
    await prefs.setBool('dndAuto', _dnd.autoApply);
    final bm = _bg.toMap();
    await prefs.setString('bgType', bm['type']!);
    await prefs.setString('bgColor', bm['color']!);
    await prefs.setString('bgGrad1', bm['grad1']!);
    await prefs.setString('bgGrad2', bm['grad2']!);
    await prefs.setString('bgImage', bm['image']!);
    await prefs.setString('bgOpacity', bm['opacity']!);
    await prefs.setString('bgBlur', bm['blur']!);
    await prefs.setStringList(
      'overrides',
      _overrides.entries.map((e) => '${e.key}|${e.value}').toList(),
    );
  }

  String _key(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  bool _sameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  ShiftType _shiftFor(DateTime date) {
    final k = _key(date);
    if (_overrides.containsKey(k)) {
      final name = _overrides[k]!;
      return ShiftType.values.firstWhere(
        (e) => e.name == name,
        orElse: () => ShiftType.rest,
      );
    }
    final d0 = DateTime(_cycleStart.year, _cycleStart.month, _cycleStart.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = d.difference(d0).inDays;
    final total = diff + _group;
    final index = ((total % 3) + 3) % 3;
    return _cycle[index];
  }

  String _shiftTimeText(ShiftType s) {
    switch (s) {
      case ShiftType.day:
        return rangeText(_shift.dayStart, _shift.dayEnd);
      case ShiftType.night:
        return rangeText(_shift.nightStart, _shift.nightEnd);
      case ShiftType.rest:
        return '休息 24 小时';
    }
  }

  Map<ShiftType, int> _monthStats() {
    final first = DateTime(_focusedDay.year, _focusedDay.month, 1);
    final last = DateTime(_focusedDay.year, _focusedDay.month + 1, 0);
    final map = {for (final s in ShiftType.values) s: 0};
    for (var d = first; !d.isAfter(last); d = d.add(const Duration(days: 1))) {
      final s = _shiftFor(d);
      map[s] = (map[s] ?? 0) + 1;
    }
    return map;
  }

  Future<void> _loadWeather() async {
    try {
      final w = await WeatherService.fetchDaily();
      if (mounted) setState(() => _weather = w);
    } catch (_) {}
  }

  Future<void> _rescheduleAlarms() async {
    await NotificationService.cancelAll();
    if (!_alarm.enabled) return;
    final now = DateTime.now();
    var id = 0;
    for (var i = 0; i < 14; i++) {
      final d = now.add(Duration(days: i));
      final s = _shiftFor(d);
      if (s == ShiftType.rest) continue;
      final start = s == ShiftType.day ? _shift.dayStart : _shift.nightStart;
      final end = s == ShiftType.day ? _shift.dayEnd : _shift.nightEnd;
      final startDT =
          DateTime(d.year, d.month, d.day, start.hour, start.minute);
      final alarmTime =
          startDT.subtract(Duration(minutes: _alarm.minutesBefore));
      if (alarmTime.isBefore(now)) continue;
      await NotificationService.schedule(
        id: id++,
        when: alarmTime,
        title: '${s.label}提醒',
        body:
            '${DateFormat('M月d日').format(d)} ${rangeText(start, end)}，${_alarm.minutesBefore}分钟后上班',
      );
    }
  }

  void _startDndWatcher() {
    _dndTimer?.cancel();
    if (!_dnd.enabled || !_dnd.autoApply) {
      DndService.setDnd(false);
      return;
    }
    _checkDnd();
    _dndTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkDnd());
  }

  bool _inDndRange(DateTime now) {
    final cur = now.hour * 60 + now.minute;
    final s = _dnd.start.hour * 60 + _dnd.start.minute;
    final e = _dnd.end.hour * 60 + _dnd.end.minute;
    if (s <= e) return cur >= s && cur < e;
    return cur >= s || cur < e;
  }

  Future<void> _checkDnd() async {
    if (!await DndService.hasPermission()) return;
    final shouldOn = _inDndRange(DateTime.now());
    await DndService.setDnd(shouldOn);
  }

  Future<void> _showShiftPicker(DateTime day) async {
    final current = _shiftFor(day);
    final isOverridden = _overrides.containsKey(_key(day));
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white.withOpacity(0.95),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${DateFormat('yyyy年M月d日 EEEE', 'zh_CN').format(day)}\n当前：${current.label}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              for (final s in ShiftType.values)
                ListTile(
                  leading: CircleAvatar(backgroundColor: s.color, radius: 10),
                  title: Text(s.label),
                  subtitle: Text(_shiftTimeText(s)),
                  trailing: current == s ? const Icon(Icons.check) : null,
                  onTap: () async {
                    setState(() => _overrides[_key(day)] = s.name);
                    await _save();
                    await _rescheduleAlarms();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              if (isOverridden)
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('恢复自动排班'),
                  onTap: () async {
                    setState(() => _overrides.remove(_key(day)));
                    await _save();
                    await _rescheduleAlarms();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<AppSettings>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          initial: AppSettings(
            group: _group,
            cycleStart: _cycleStart,
            shift: ShiftConfig(
              dayStart: _shift.dayStart,
              dayEnd: _shift.dayEnd,
              nightStart: _shift.nightStart,
              nightEnd: _shift.nightEnd,
            ),
            alarm: AlarmConfig(
              enabled: _alarm.enabled,
              minutesBefore: _alarm.minutesBefore,
            ),
            dnd: DndConfig(
              enabled: _dnd.enabled,
              start: _dnd.start,
              end: _dnd.end,
              autoApply: _dnd.autoApply,
            ),
            bg: BackgroundConfig(
              type: _bg.type,
              color: _bg.color,
              gradient: List.of(_bg.gradient),
              imagePath: _bg.imagePath,
              opacity: _bg.opacity,
              blur: _bg.blur,
            ),
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _group = result.group;
        _cycleStart = DateTime(result.cycleStart.year,
            result.cycleStart.month, result.cycleStart.day);
        _shift = result.shift;
        _alarm = result.alarm;
        _dnd = result.dnd;
        _bg = result.bg;
      });
      await _save();
      await _rescheduleAlarms();
      _startDndWatcher();
    }
  }

  Widget _glassCard({required Widget child, EdgeInsets? margin}) {
    return Container(
      margin: margin ?? EdgeInsets.zero,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _todayCard() {
    final today = DateTime.now();
    final tomorrow = today.add(const Duration(days: 1));
    final t1 = _shiftFor(today);
    final t2 = _shiftFor(tomorrow);

    Widget row(String prefix, DateTime d, ShiftType s) {
      final w = _weather[_key(d)];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(prefix,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text(DateFormat('M月d日 EEEE', 'zh_CN').format(d),
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const Spacer(),
              if (w != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '${WeatherService.codeToInfo(w['code'] as int)['icon']}'
                    '${(w['tempMin'] as num).round()}~${(w['tempMax'] as num).round()}°',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: s.color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(s.label,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_shiftTimeText(s), style: const TextStyle(fontSize: 12)),
        ],
      );
    }

    return _glassCard(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('今日', today, t1),
            const Divider(height: 16),
            row('明日', tomorrow, t2),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _monthStats();
    final workDays =
        (stats[ShiftType.day] ?? 0) + (stats[ShiftType.night] ?? 0);
    final totalHours =
        (stats[ShiftType.day] ?? 0) * _shift.dayHours +
            (stats[ShiftType.night] ?? 0) * _shift.nightHours;
    final hoursStr = totalHours == totalHours.roundToDouble()
        ? totalHours.toStringAsFixed(0)
        : totalHours.toStringAsFixed(1);

    return AppBackground(
      config: _bg,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('${_groups[_group]} · 上12休24'),
          actions: [
            IconButton(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              tooltip: '设置',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  WeatherService.clearCache();
                  await _loadWeather();
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      _todayCard(),
                      const SizedBox(height: 8),
                      _glassCard(
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: TableCalendar(
                            locale: 'zh_CN',
                            firstDay: DateTime(2020),
                            lastDay: DateTime(2035),
                            focusedDay: _focusedDay,
                            selectedDayPredicate: (d) =>
                                isSameDay(d, _selectedDay),
                            calendarFormat: CalendarFormat.month,
                            availableCalendarFormats: const {
                              CalendarFormat.month: '月'
                            },
                            rowHeight: 62,
                            daysOfWeekHeight: 26,
                            headerStyle: const HeaderStyle(
                              formatButtonVisible: false,
                              titleCentered: true,
                              decoration: BoxDecoration(
                                  color: Colors.transparent),
                            ),
                            calendarStyle: CalendarStyle(
                              outsideDaysVisible: false,
                              todayDecoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.12),
                                shape: BoxShape.circle,
                              ),
                              selectedDecoration: const BoxDecoration(
                                  color: Colors.transparent),
                            ),
                            onDaySelected: (selected, focused) {
                              setState(() {
                                _selectedDay = selected;
                                _focusedDay = focused;
                              });
                              _showShiftPicker(selected);
                            },
                            onPageChanged: (focused) {
                              setState(() => _focusedDay = focused);
                            },
                            calendarBuilders: CalendarBuilders(
                              defaultBuilder: (context, day, focusedDay) {
                                final inMonth = _sameMonth(day, focusedDay);
                                final shift = _shiftFor(day);
                                final isToday = isSameDay(day, DateTime.now());
                                final isSelected = isSameDay(day, _selectedDay);
                                final w = _weather[_key(day)];
                                return Container(
                                  margin: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? shift.color.withOpacity(0.22)
                                        : null,
                                    border: isToday
                                        ? Border.all(
                                            color: Colors.red, width: 1.5)
                                        : null,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '${day.day}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: inMonth
                                              ? Colors.black87
                                              : Colors.black26,
                                          fontWeight: isToday
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      if (inMonth)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(top: 1),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 3, vertical: 0.5),
                                          decoration: BoxDecoration(
                                            color: shift.color,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                          child: Text(
                                            shift.label,
                                            style: const TextStyle(
                                                fontSize: 8,
                                                color: Colors.white),
                                          ),
                                        ),
                                      if (inMonth && w != null)
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            '${WeatherService.codeToInfo(w['code'] as int)['icon']}'
                                            '${(w['tempMin'] as num).round()}~${(w['tempMax'] as num).round()}°',
                                            style: const TextStyle(
                                                fontSize: 7.5,
                                                color: Colors.grey),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _glassCard(
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_focusedDay.year}年${_focusedDay.month}月统计',
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  _statItem('白班', stats[ShiftType.day] ?? 0,
                                      ShiftType.day.color),
                                  _statItem(
                                      '夜班',
                                      stats[ShiftType.night] ?? 0,
                                      ShiftType.night.color),
                                  _statItem(
                                      '休息',
                                      stats[ShiftType.rest] ?? 0,
                                      ShiftType.rest.color),
                                ],
                              ),
                              const Divider(height: 20),
                              Text(
                                '上班 $workDays 天    总工时约 $hoursStr 小时',
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '白班 ${_shift.dayHours.toStringAsFixed(1)} 小时/班 · '
                                '夜班 ${_shift.nightHours.toStringAsFixed(1)} 小时/班',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Colors.white.withOpacity(0.55),
              child: Text(
                '${_groups[_group]} · 白→夜→休 3天循环 · 点击日期可手动改班',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, int count, Color color) {
    return Column(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(height: 4),
        Text('$count 天', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  final AppSettings initial;
  const SettingsPage({super.key, required this.initial});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late int _group;
  late DateTime _cycleStart;
  late ShiftConfig _shift;
  late AlarmConfig _alarm;
  late DndConfig _dnd;
  late BackgroundConfig _bg;

  static const _groups = ['甲组', '乙组', '丙组'];
  static const _presetColors = [
    Color(0xFFF1F5FB),
    Color(0xFFFFFFFF),
    Color(0xFFFFF3E0),
    Color(0xFFE8F5E9),
    Color(0xFFF3E5F5),
    Color(0xFFE3F2FD),
    Color(0xFF263238),
    Color(0xFF1A1A2E),
  ];
  static const _presetGradients = [
    [Color(0xFFE8F0FE), Color(0xFFF7F9FC)],
    [Color(0xFFFFF1E6), Color(0xFFFDE8EE)],
    [Color(0xFFE0F7FA), Color(0xFFE8F5E9)],
    [Color(0xFFF3E5F5), Color(0xFFE8EAF6)],
    [Color(0xFF1A1A2E), Color(0xFF16213E)],
    [Color(0xFF232946), Color(0xFF121629)],
  ];

  @override
  void initState() {
    super.initState();
    _group = widget.initial.group;
    _cycleStart = widget.initial.cycleStart;
    _shift = widget.initial.shift;
    _alarm = widget.initial.alarm;
    _dnd = widget.initial.dnd;
    _bg = widget.initial.bg;
  }

  Future<void> _pickTime(
      TimeOfDay current, ValueChanged<TimeOfDay> onPicked) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) onPicked(picked);
  }

  Widget _timeTile(String title, String subtitle, TimeOfDay time,
      ValueChanged<TimeOfDay> onPicked) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: Text(
        fmtTime(time),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      onTap: () => _pickTime(time, (v) {
        setState(() => onPicked(v));
      }),
    );
  }

  bool _listEquals(List<Color> a, List<Color> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i].value == b[i].value).every((e) => e);

  @override
  Widget build(BuildContext context) {
    final dayRange = rangeText(_shift.dayStart, _shift.dayEnd);
    final nightRange = rangeText(_shift.nightStart, _shift.nightEnd);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        title: const Text('排班设置'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(
                context,
                AppSettings(
                  group: _group,
                  cycleStart: _cycleStart,
                  shift: _shift,
                  alarm: _alarm,
                  dnd: _dnd,
                  bg: _bg,
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('班组与循环',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          const Text(
            '规则：上12休24，3天循环\n'
            '每个人：白班 → 夜班 → 休息 → 白班…\n'
            '甲乙丙三组错开一天，每天一组白、一组夜、一组休。\n'
            '不是固定白夜，三组会轮流倒。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            value: _group,
            decoration: const InputDecoration(
              labelText: '我的班组',
              border: OutlineInputBorder(),
            ),
            items: [
              for (var i = 0; i < 3; i++)
                DropdownMenuItem(value: i, child: Text(_groups[i])),
            ],
            onChanged: (v) => setState(() => _group = v ?? 0),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('循环起始日'),
            subtitle: Text(
              '${DateFormat('yyyy-MM-dd').format(_cycleStart)}\n'
              '该日甲组白班、乙组夜班、丙组休息\n'
              '之后每天三组依次轮换',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _cycleStart,
                firstDate: DateTime(2020),
                lastDate: DateTime(2035),
              );
              if (picked != null) setState(() => _cycleStart = picked);
            },
          ),
          const Divider(height: 32),
          const Text('白班时间',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          Text(dayRange,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          _timeTile('白班开始', '点右侧时间修改', _shift.dayStart,
              (v) => setState(() => _shift.dayStart = v)),
          _timeTile('白班结束', '若结束时间早于开始时间，视为次日', _shift.dayEnd,
              (v) => setState(() => _shift.dayEnd = v)),
          const Divider(height: 32),
          const Text('夜班时间',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          Text(nightRange,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          _timeTile('夜班开始', '点右侧时间修改', _shift.nightStart,
              (v) => setState(() => _shift.nightStart = v)),
          _timeTile('夜班结束', '若结束时间早于开始时间，视为次日', _shift.nightEnd,
              (v) => setState(() => _shift.nightEnd = v)),
          const Divider(height: 32),
          const Text('上班闹钟',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('开启上班提醒'),
            subtitle: const Text('按排班自动在上班前提醒'),
            value: _alarm.enabled,
            onChanged: (v) => setState(() => _alarm.enabled = v),
          ),
          if (_alarm.enabled)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('提前提醒'),
              trailing: DropdownButton<int>(
                value: _alarm.minutesBefore,
                items: const [
                  DropdownMenuItem(value: 10, child: Text('10 分钟')),
                  DropdownMenuItem(value: 20, child: Text('20 分钟')),
                  DropdownMenuItem(value: 30, child: Text('30 分钟')),
                  DropdownMenuItem(value: 60, child: Text('1 小时')),
                  DropdownMenuItem(value: 120, child: Text('2 小时')),
                ],
                onChanged: (v) =>
                    setState(() => _alarm.minutesBefore = v ?? 30),
              ),
            ),
          const Divider(height: 32),
          const Text('免打扰',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const Text(
            'Android：到时间段自动开启系统勿扰（需授权一次）\n'
            'iOS：系统不允许 App 自动开关勿扰，只能到点发通知提醒',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('开启免打扰时间段'),
            value: _dnd.enabled,
            onChanged: (v) => setState(() => _dnd.enabled = v),
          ),
          if (_dnd.enabled) ...[
            _timeTile('免打扰开始', '每天从这时开始', _dnd.start,
                (v) => setState(() => _dnd.start = v)),
            _timeTile('免打扰结束', '到这时自动关闭', _dnd.end,
                (v) => setState(() => _dnd.end = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动切换（仅 Android）'),
              value: _dnd.autoApply,
              onChanged: (v) => setState(() => _dnd.autoApply = v),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_outlined),
              title: const Text('授予勿扰权限'),
              subtitle: const Text('Android 需在系统设置里允许本应用修改勿扰'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => DndService.openSettings(),
            ),
          ],
          const Divider(height: 32),
          const Text('背景',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          SegmentedButton<BgType>(
            segments: const [
              ButtonSegment(value: BgType.color, label: Text('纯色')),
              ButtonSegment(value: BgType.gradient, label: Text('渐变')),
              ButtonSegment(value: BgType.image, label: Text('图片')),
            ],
            selected: {_bg.type},
            onSelectionChanged: (s) => setState(() => _bg.type = s.first),
          ),
          const SizedBox(height: 12),
          if (_bg.type == BgType.color)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in _presetColors)
                  GestureDetector(
                    onTap: () => setState(() => _bg.color = c),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _bg.color == c
                              ? Colors.blue
                              : Colors.grey.shade300,
                          width: _bg.color == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (_bg.type == BgType.gradient)
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final g in _presetGradients)
                  GestureDetector(
                    onTap: () => setState(() => _bg.gradient = g),
                    child: Container(
                      width: 56,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: LinearGradient(
                          colors: g,
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        border: Border.all(
                          color: _listEquals(_bg.gradient, g)
                              ? Colors.blue
                              : Colors.grey.shade300,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (_bg.type == BgType.image) ...[
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final picker = ImagePicker();
                    final x = await picker.pickImage(
                      source: ImageSource.gallery,
                      maxWidth: 1920,
                      imageQuality: 85,
                    );
                    if (x != null) setState(() => _bg.imagePath = x.path);
                  },
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('从相册选择'),
                ),
                const SizedBox(width: 8),
                if (_bg.imagePath != null)
                  TextButton(
                    onPressed: () => setState(() => _bg.imagePath = null),
                    child: const Text('清除'),
                  ),
              ],
            ),
            if (_bg.imagePath != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_bg.imagePath!),
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Text('背景透出程度 ${(_bg.opacity * 100).round()}%',
              style: const TextStyle(fontSize: 13)),
          Slider(
            value: _bg.opacity,
            min: 0.3,
            max: 1.0,
            divisions: 14,
            label: '${(_bg.opacity * 100).round()}%',
            onChanged: (v) => setState(() => _bg.opacity = v),
          ),
          if (_bg.type == BgType.image) ...[
            Text('背景模糊 ${_bg.blur.round()}',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _bg.blur,
              min: 0,
              max: 20,
              divisions: 20,
              label: '${_bg.blur.round()}',
              onChanged: (v) => setState(() => _bg.blur = v),
            ),
          ],
          const Divider(height: 32),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('当前工时',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('白班：${_shift.dayHours.toStringAsFixed(2)} 小时/班'),
                  Text('夜班：${_shift.nightHours.toStringAsFixed(2)} 小时/班'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
