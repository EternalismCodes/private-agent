import '../agent/safe_cast.dart';
import '../models/agent_action.dart';
import '../models/chat_message.dart';
import 'app_launcher_service.dart';
import 'contacts_service.dart';
import 'communication_service.dart';
import 'alarm_service.dart';
import 'system_control_service.dart';
import 'shizuku_service.dart';
import 'screen_automation_service.dart';
import 'task_executor.dart';
import 'ai_service.dart';
import 'weather_service.dart';
import 'youtube_service.dart';

class ActionHandler {
  final AppLauncherService _appLauncher = AppLauncherService();
  final ContactsService _contacts = ContactsService();
  final CommunicationService _communication = CommunicationService();
  final AlarmService _alarm = AlarmService();
  final SystemControlService _systemControl = SystemControlService();
  final ShizukuService _shizuku = ShizukuService();
  final ScreenAutomationService _screenAutomation = ScreenAutomationService();
  final WeatherService _weather = WeatherService();
  final YoutubeService _youtube = YoutubeService();

  ShizukuService get shizuku => _shizuku;
  AppLauncherService get appLauncher => _appLauncher;
  ScreenAutomationService get screenAutomation => _screenAutomation;

  /// The currently running task executor, if any
  TaskExecutor? _currentExecutor;

  String _ytQuery = '';
  DateTime? _ytAt;

  /// Last YouTube search (within 20 min), so "play the top result" knows what to play.
  String get recentYoutubeQuery =>
      (_ytAt != null && DateTime.now().difference(_ytAt!) < const Duration(minutes: 20)) ? _ytQuery : '';

  void noteYoutubeQuery(String q) {
    _ytQuery = q.trim();
    _ytAt = DateTime.now();
  }

  static String _s(dynamic v, [String d = '']) => v == null ? d : v.toString().trim();
  static String? _sn(dynamic v) {
    final s = _s(v);
    return s.isEmpty ? null : s;
  }

  static const Set<String> _strict = {'set_alarm', 'set_timer', 'get_weather', 'play_youtube'};
  static final RegExp _failed = RegExp(r'^(error|could not|cannot|unable)', caseSensitive: false);

  /// Execute an action and return the result
  Future<AgentActionResult> execute(
    AgentAction action, {
    AiService? aiService,
    void Function(String)? onProgress,
  }) async {
    try {
      String result;
      final p = action.params;

      switch (action.action) {
        case 'open_app':
          result = await _appLauncher.openApp(_s(p['app_name']));
          break;

        case 'launch_package':
          result = await _appLauncher.openPackage(_s(p['package_name']));
          break;

        case 'make_call':
          result = await _communication.makeCall(
            contactName: _sn(p['contact_name']),
            phoneNumber: _sn(p['phone_number']),
          );
          break;

        case 'send_sms':
          result = await _communication.sendSms(
            contactName: _sn(p['contact_name']),
            phoneNumber: _sn(p['phone_number']),
            message: _s(p['message']),
          );
          break;

        case 'search_contact':
          result = await _contacts.searchAndFormat(_s(p['query']));
          break;

        case 'set_alarm':
          final clock = parseClock(p);
          result = clock == null
              ? 'Could not set the alarm: I need a valid time.'
              : await _alarm.setAlarm(hour: clock.hour, minute: clock.minute, label: _sn(p['label']));
          break;

        case 'set_timer':
          final secs = parseDurationSeconds(p);
          result = secs == null
              ? 'Could not set the timer: I need a duration.'
              : await _alarm.setTimer(seconds: secs, label: _sn(p['label']));
          break;

        case 'set_volume':
          result = await _systemControl.setVolume(asInt(p['level']) ?? 50);
          break;

        case 'set_brightness':
          result = await _systemControl.setBrightness(asInt(p['level']) ?? 50);
          break;

        case 'get_weather':
          result = await _weather.forecast(
            _s(p['location'] ?? p['city'] ?? p['place']),
            days: asInt(p['days']) ?? 1,
            fahrenheit: _s(p['unit']).toLowerCase().startsWith('f'),
          );
          break;

        case 'play_youtube':
          var q = _s(p['query'] ?? p['search'] ?? p['title']);
          if (q.isEmpty) q = recentYoutubeQuery;
          final rank = asInt(p['rank']) ?? 1;
          result = await _youtube.play(q, rank: rank < 1 ? 1 : (rank > 10 ? 10 : rank), screen: _screenAutomation);
          if (q.isNotEmpty) noteYoutubeQuery(q);
          break;

        case 'run_adb_command':
          result = await _shizuku.runCommand(_s(p['command']));
          break;

        case 'send_email':
          result = await _communication.sendEmail(
            to: _s(p['to']),
            subject: _sn(p['subject']),
            body: _sn(p['body']),
          );
          break;

        case 'open_url':
          result = await _appLauncher.openUrl(_s(p['url']));
          break;

        // ─── Screen Automation Actions ────────────────────────

        case 'read_screen':
          result = await _screenAutomation.getScreenDescription();
          break;

        case 'click_element':
          final text = _s(p['text']);
          final success = await _screenAutomation.clickByText(text);
          result = success ? 'Clicked "$text"' : 'Could not find "$text" to click';
          break;

        case 'type_on_screen':
          final text = _s(p['text']);
          final success = await _screenAutomation.typeText(text, fieldHint: _sn(p['field_hint']));
          result = success ? 'Typed "$text"' : 'Could not type into field';
          break;

        case 'scroll_screen':
          final direction = _s(p['direction'], 'down');
          final success = await _screenAutomation.scroll(direction);
          result = success ? 'Scrolled $direction' : 'Could not scroll';
          break;

        case 'press_back':
          final success = await _screenAutomation.pressBack();
          result = success ? 'Pressed back' : 'Could not press back';
          break;

        // ─── Multi-Step Task Execution ────────────────────────

        case 'execute_task':
          final goal = _s(p['goal'], action.response);
          if (aiService == null) {
            result = 'AI service not available for task execution.';
            break;
          }
          _currentExecutor = TaskExecutor(
            aiService: aiService,
            screenService: _screenAutomation,
            appLauncher: _appLauncher,
            shizukuService: _shizuku,
            onProgress: onProgress,
          );
          result = await _currentExecutor!.executeTask(goal);
          _currentExecutor = null;
          break;

        default:
          result = action.response;
      }

      final ok = !(_strict.contains(action.action) && _failed.hasMatch(result.trim()));
      return AgentActionResult(actionType: action.action, success: ok, details: result);
    } catch (e) {
      return AgentActionResult(actionType: action.action, success: false, details: 'Error: $e');
    }
  }

  /// Cancel the currently running task
  void cancelTask() {
    _currentExecutor?.cancel();
  }
}
