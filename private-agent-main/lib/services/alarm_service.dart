import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/services.dart';

class AlarmService {
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static const MethodChannel _clock = MethodChannel('com.privateagent/clock');

  Future<bool> _launch(String action, Map<String, dynamic> args) async {
    try {
      await AndroidIntent(
        action: action,
        arguments: <String, dynamic>{...args, 'android.intent.extra.alarm.SKIP_UI': true},
        flags: _newTask,
      ).launch();
      return true;
    } catch (_) {}
    try {
      await AndroidIntent(action: action, arguments: args, flags: _newTask).launch();
      return true;
    } catch (_) {}
    return false;
  }

  /// PrivateAgent's own alarm (works with no Clock app handling the intent).
  Future<bool> _own(DateTime at, String label, String kind) async {
    try {
      return await _clock.invokeMethod<bool>('schedule', {
            'at': at.millisecondsSinceEpoch,
            'label': label,
            'kind': kind,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<String> setAlarm({required int hour, required int minute, String? label}) async {
    final l = label ?? '';
    final t = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    final ok = await _launch('android.intent.action.SET_ALARM', <String, dynamic>{
      'android.intent.extra.alarm.HOUR': hour,
      'android.intent.extra.alarm.MINUTES': minute,
      if (l.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': l,
    });
    if (ok) return 'Alarm set for $t${l.isNotEmpty ? ' ($l)' : ''}';
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, hour, minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    if (await _own(at, l, 'alarm')) return 'Alarm set for $t${l.isNotEmpty ? ' ($l)' : ''} (PrivateAgent alarm; your Clock app did not accept the request)';
    return 'Could not set the alarm: neither the Clock app nor PrivateAgent could schedule it.';
  }

  Future<String> setTimer({required int seconds, String? label}) async {
    final l = label ?? '';
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    final d = [if (h > 0) '${h}h', if (m > 0) '${m}m', if (s > 0 || (h == 0 && m == 0)) '${s}s'].join(' ');
    final ok = await _launch('android.intent.action.SET_TIMER', <String, dynamic>{
      'android.intent.extra.alarm.LENGTH': seconds,
      if (l.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': l,
    });
    if (ok) return 'Timer set for $d${l.isNotEmpty ? ' ($l)' : ''}';
    if (await _own(DateTime.now().add(Duration(seconds: seconds)), l, 'timer')) {
      return 'Timer set for $d${l.isNotEmpty ? ' ($l)' : ''} (PrivateAgent timer; your Clock app did not accept the request)';
    }
    return 'Could not set the timer: neither the Clock app nor PrivateAgent could schedule it.';
  }
}
