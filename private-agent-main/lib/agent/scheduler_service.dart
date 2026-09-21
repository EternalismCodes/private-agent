import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'agent_mode.dart';
import 'json_utils.dart';

class ScheduledTask {
  final String id;
  String goal;

  /// AgentMode id: 'auto' or 'planExecute'.
  String mode;

  /// 'none', 'daily', 'weekdays' or 'weekly'.
  String repeat;

  /// First run for one-off tasks; for repeating tasks its time of day (and,
  /// for weekly tasks, its weekday) is used.
  DateTime anchor;
  DateTime? nextRun;
  bool enabled;
  DateTime? lastRun;
  String lastStatus;

  ScheduledTask({
    required this.id,
    required this.goal,
    this.mode = 'auto',
    this.repeat = 'none',
    required this.anchor,
    this.nextRun,
    this.enabled = true,
    this.lastRun,
    this.lastStatus = '',
  });

  AgentMode get agentMode => AgentModeInfo.fromId(mode);

  /// Next occurrence strictly after [after], or null for a finished one-off.
  DateTime? computeNextRun(DateTime after) {
    switch (repeat) {
      case 'daily':
        for (var i = 0; i < 3; i++) {
          final c = DateTime(after.year, after.month, after.day + i, anchor.hour, anchor.minute);
          if (c.isAfter(after)) return c;
        }
        return null;
      case 'weekdays':
        for (var i = 0; i < 9; i++) {
          final c = DateTime(after.year, after.month, after.day + i, anchor.hour, anchor.minute);
          if (c.isAfter(after) && c.weekday <= DateTime.friday) return c;
        }
        return null;
      case 'weekly':
        for (var i = 0; i < 9; i++) {
          final c = DateTime(after.year, after.month, after.day + i, anchor.hour, anchor.minute);
          if (c.isAfter(after) && c.weekday == anchor.weekday) return c;
        }
        return null;
      default:
        return anchor.isAfter(after) ? anchor : null;
    }
  }

  String get repeatLabel => switch (repeat) {
        'daily' => 'Every day',
        'weekdays' => 'Weekdays',
        'weekly' => 'Every week',
        _ => 'Once',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'goal': goal,
        'mode': mode,
        'repeat': repeat,
        'anchor': anchor.toIso8601String(),
        'next_run': nextRun?.toIso8601String(),
        'enabled': enabled,
        'last_run': lastRun?.toIso8601String(),
        'last_status': lastStatus,
      };

  factory ScheduledTask.fromJson(Map<String, dynamic> json) => ScheduledTask(
        id: JsonUtils.str(json['id'], DateTime.now().microsecondsSinceEpoch.toString()),
        goal: JsonUtils.str(json['goal']),
        mode: JsonUtils.str(json['mode'], 'auto'),
        repeat: JsonUtils.str(json['repeat'], 'none'),
        anchor: DateTime.tryParse(JsonUtils.str(json['anchor'])) ?? DateTime.now(),
        nextRun: DateTime.tryParse(JsonUtils.str(json['next_run'])),
        enabled: JsonUtils.boolOf(json['enabled'], true),
        lastRun: DateTime.tryParse(JsonUtils.str(json['last_run'])),
        lastStatus: JsonUtils.str(json['last_status']),
      );
}

/// Keeps the list of scheduled tasks, registers wake-up alarms with Android and
/// fires due tasks while the app is running.
class SchedulerService {
  SchedulerService._();
  static final SchedulerService instance = SchedulerService._();

  static const MethodChannel _channel = MethodChannel('com.privateagent/scheduler');

  /// Tasks that became due more than this long ago are skipped, not run.
  static const Duration grace = Duration(hours: 6);

  final List<ScheduledTask> _items = [];
  bool _loaded = false;
  Timer? _ticker;
  bool _checking = false;

  List<ScheduledTask> get items => List.unmodifiable(_items);

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/scheduled_tasks.json');
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _items.clear();
    try {
      final f = await _file();
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) _items.add(ScheduledTask.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_items.map((t) => t.toJson()).toList()), flush: true);
    } catch (_) {}
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  // ─── Native alarms ─────────────────────────────────────────────────────

  Future<void> _nativeSchedule(ScheduledTask t) async {
    try {
      final next = t.nextRun;
      if (!t.enabled || next == null) {
        await _channel.invokeMethod('cancel', {'id': t.id});
        return;
      }
      if (!next.isAfter(DateTime.now())) return; // already due: ticker runs it
      await _channel.invokeMethod('schedule', {
        'id': t.id,
        'goal': t.goal,
        'triggerAt': next.millisecondsSinceEpoch,
      });
    } catch (_) {
      // Native side unavailable (tests, other engine): the in-app ticker
      // still runs the task while the app is open.
    }
  }

  Future<bool> canScheduleExact() async {
    try {
      return await _channel.invokeMethod<bool>('canScheduleExact') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod('openExactAlarmSettings');
    } catch (_) {}
  }

  /// Registers every enabled task with Android again (call at app start).
  Future<void> syncAlarms() async {
    await load();
    for (final t in _items) {
      await _nativeSchedule(t);
    }
  }

  // ─── CRUD ──────────────────────────────────────────────────────────────

  Future<ScheduledTask> add({
    required String goal,
    required DateTime when,
    String repeat = 'none',
    String mode = 'auto',
  }) async {
    await load();
    final task = ScheduledTask(
      id: newId(),
      goal: goal.trim(),
      mode: mode,
      repeat: repeat,
      anchor: when,
    );
    task.nextRun = task.computeNextRun(DateTime.now());
    if (task.nextRun == null) task.enabled = false;
    _items.add(task);
    await _persist();
    await _nativeSchedule(task);
    return task;
  }

  Future<void> update(ScheduledTask task) async {
    await load();
    if (task.enabled) {
      task.nextRun = task.computeNextRun(DateTime.now());
      if (task.nextRun == null) task.enabled = false;
    }
    await _persist();
    await _nativeSchedule(task);
  }

  Future<void> setEnabled(ScheduledTask task, bool enabled) async {
    task.enabled = enabled;
    if (enabled) {
      task.nextRun = task.computeNextRun(DateTime.now());
      if (task.repeat == 'none' && task.nextRun == null) task.enabled = false;
    }
    await _persist();
    await _nativeSchedule(task);
  }

  Future<void> remove(ScheduledTask task) async {
    await load();
    _items.removeWhere((t) => t.id == task.id);
    await _persist();
    try {
      await _channel.invokeMethod('cancel', {'id': task.id});
    } catch (_) {}
  }

  // ─── Running due tasks ────────────────────────────────────────────────

  /// Starts a periodic check. [canRun] tells the scheduler whether the agent
  /// is free; [runner] executes the task and returns a short status.
  void start({
    required bool Function() canRun,
    required Future<String> Function(ScheduledTask task) runner,
  }) {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      checkDue(canRun: canRun, runner: runner);
    });
    checkDue(canRun: canRun, runner: runner);
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> checkDue({
    required bool Function() canRun,
    required Future<String> Function(ScheduledTask task) runner,
  }) async {
    if (_checking) return;
    _checking = true;
    try {
      await load();
      final now = DateTime.now();
      for (final t in List<ScheduledTask>.from(_items)) {
        final due = t.nextRun;
        if (!t.enabled || due == null || due.isAfter(now)) continue;

        if (now.difference(due) > grace) {
          t.lastStatus = 'Missed';
          _advance(t, now);
          await _persist();
          await _nativeSchedule(t);
          continue;
        }
        if (!canRun()) return;

        // Move the schedule forward first so a crash cannot re-trigger it.
        t.lastRun = now;
        t.lastStatus = 'Running';
        _advance(t, now);
        await _persist();
        await _nativeSchedule(t);

        String status;
        try {
          status = await runner(t);
        } catch (e) {
          status = 'Failed';
        }
        t.lastStatus = status;
        await _persist();
        return; // one task per tick keeps the agent from overlapping runs
      }
    } finally {
      _checking = false;
    }
  }

  void _advance(ScheduledTask t, DateTime now) {
    if (t.repeat == 'none') {
      t.enabled = false;
      t.nextRun = null;
    } else {
      t.nextRun = t.computeNextRun(now);
    }
  }

  /// Parses "YYYY-MM-DD HH:MM" (also with a "T") in local time.
  static DateTime? parseWhen(String text) {
    final cleaned = text.trim().replaceFirst(' ', 'T');
    return DateTime.tryParse(cleaned);
  }
}
