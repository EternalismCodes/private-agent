import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

class AlarmService {
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];

  /// Launches the clock app's intent; retries without SKIP_UI (some clock
  /// apps refuse it) and finally reports failure instead of lying.
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

  Future<String> setAlarm({required int hour, required int minute, String? label}) async {
    final ok = await _launch('android.intent.action.SET_ALARM', <String, dynamic>{
      'android.intent.extra.alarm.HOUR': hour,
      'android.intent.extra.alarm.MINUTES': minute,
      if (label != null && label.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': label,
    });
    final t = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return ok
        ? 'Alarm set for $t${label != null && label.isNotEmpty ? ' ($label)' : ''}'
        : 'Could not set the alarm: no clock app accepted the request.';
  }

  Future<String> setTimer({required int seconds, String? label}) async {
    final ok = await _launch('android.intent.action.SET_TIMER', <String, dynamic>{
      'android.intent.extra.alarm.LENGTH': seconds,
      if (label != null && label.isNotEmpty) 'android.intent.extra.alarm.MESSAGE': label,
    });
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    final d = [if (h > 0) '${h}h', if (m > 0) '${m}m', if (s > 0 || (h == 0 && m == 0)) '${s}s'].join(' ');
    return ok
        ? 'Timer set for $d${label != null && label.isNotEmpty ? ' ($label)' : ''}'
        : 'Could not set the timer: no clock app accepted the request.';
  }
}
