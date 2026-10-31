import 'dart:async';
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
import 'netflix_service.dart';
import 'whatsapp_service.dart';
import 'call_talk_session.dart';
import 'assist_service.dart';
import 'ai_delegate_service.dart';
import 'cable_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../lab/lab_vision.dart';
import '../lab/teach.dart';
import 'ir_service.dart';
import 'favorites_service.dart';
import 'camera_service.dart';
import 'location_service.dart';
import 'quick_settings_service.dart';
import '../agent/people_book.dart';

class ActionHandler {
  final AppLauncherService _appLauncher = AppLauncherService();
  final ContactsService _contacts = ContactsService();
  final CommunicationService _communication = CommunicationService();
  final AlarmService _alarm = AlarmService();
  final SystemControlService _systemControl = SystemControlService();
  final ShizukuService _shizuku = ShizukuService();
  final ScreenAutomationService _screenAutomation = ScreenAutomationService();
  late final QuickSettingsService _quickSettings = QuickSettingsService(_shizuku);
  final WeatherService _weather = WeatherService();
  final YoutubeService _youtube = YoutubeService();
  final NetflixService _netflix = NetflixService();
  final IrService _ir = IrService();
  final FavoritesService _favorites = const FavoritesService(domain: 'youtube');
  final FavoritesService _netflixFavorites = const FavoritesService(domain: 'netflix');
  final WhatsappService _whatsapp = WhatsappService();
  final CameraService _camera = CameraService();

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

  static const Set<String> _strict = {'set_alarm', 'set_timer', 'get_weather', 'play_youtube', 'play_favorite', 'play_netflix', 'play_favorite_netflix', 'analyze_screen', 'analyze_photo', 'run_taught', 'send_ir', 'save_ir', 'send_whatsapp', 'call_and_talk', 'app_assist', 'delegate_ai', 'take_photo', 'take_selfie', 'system_setting'};
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
          await PeopleBook.instance.load();
          final callWho = _sn(p['contact_name']);
          final callPerson = PeopleBook.instance.resolve(callWho ?? _sn(p['phone_number']));
          result = await _communication.makeCall(
            contactName: callPerson != null && callPerson.phone.isEmpty && callPerson.contact.isNotEmpty ? callPerson.contact : callWho,
            phoneNumber: _sn(p['phone_number']) ?? (callPerson != null && callPerson.phone.isNotEmpty ? callPerson.phone : null),
          );
          if (!_failed.hasMatch(result.trim())) {
            unawaited(PeopleBook.instance.noteUse(callPerson?.contact.isNotEmpty == true ? callPerson!.contact : (callWho ?? ''), 'Phone call'));
          }
          break;

        case 'send_sms':
          await PeopleBook.instance.load();
          final smsWho = _sn(p['contact_name']);
          final smsPerson = PeopleBook.instance.resolve(smsWho ?? _sn(p['phone_number']));
          result = await _communication.sendSms(
            contactName: smsPerson != null && smsPerson.phone.isEmpty && smsPerson.contact.isNotEmpty ? smsPerson.contact : smsWho,
            phoneNumber: _sn(p['phone_number']) ?? (smsPerson != null && smsPerson.phone.isNotEmpty ? smsPerson.phone : null),
            message: _s(p['message']),
          );
          if (!_failed.hasMatch(result.trim())) {
            unawaited(PeopleBook.instance.noteUse(smsPerson?.contact.isNotEmpty == true ? smsPerson!.contact : (smsWho ?? ''), 'SMS'));
          }
          break;

        case 'system_setting':
          final settingName = _s(p['setting'] ?? p['name']);
          var settingState = _s(p['state'] ?? p['value'], 'open').toLowerCase();
          if (const ['true', 'enable', 'enabled', 'turn on', 'on'].contains(settingState)) settingState = 'on';
          if (const ['false', 'disable', 'disabled', 'turn off', 'off'].contains(settingState)) settingState = 'off';
          if (settingState != 'on' && settingState != 'off') settingState = 'open';
          final applied = await _quickSettings.apply(settingName, settingState);
          if (applied == null) {
            result = 'Could not find a setting called "$settingName".';
            break;
          }
          result = applied.message;
          if (!applied.done && aiService != null) {
            // No direct control: the right page is open, so let the on-screen
            // automation flip the switch.
            _currentExecutor = TaskExecutor(
              aiService: aiService,
              screenService: _screenAutomation,
              appLauncher: _appLauncher,
              shizukuService: _shizuku,
              onProgress: onProgress,
            );
            result = await _currentExecutor!.executeTask(
              'The ${applied.label} settings screen is already open. Turn ${applied.label} $settingState. If it is already $settingState, change nothing and finish.',
            );
            _currentExecutor = null;
          }
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
          final place = _s(p['location'] ?? p['city'] ?? p['place']);
          if (place.isEmpty || kHereLocationRe.hasMatch(place)) {
            final loc = await LocationService.instance.current();
            if (loc == null) {
              result = 'I could not get your current location (check that Location is turned on and PrivateAgent has permission), and no place was given.';
              break;
            }
            result = await _weather.forecast(
              '',
              days: asInt(p['days']) ?? 1,
              fahrenheit: _s(p['unit']).toLowerCase().startsWith('f'),
              lat: loc.lat,
              lon: loc.lon,
              placeLabel: loc.label,
            );
          } else {
            result = await _weather.forecast(
              place,
              days: asInt(p['days']) ?? 1,
              fahrenheit: _s(p['unit']).toLowerCase().startsWith('f'),
            );
          }
          break;

        case 'play_youtube':
          var q = _s(p['query'] ?? p['search'] ?? p['title']);
          if (q.isEmpty) q = recentYoutubeQuery;
          final rank = asInt(p['rank']) ?? 1;
          result = await _youtube.play(q, rank: rank < 1 ? 1 : (rank > 10 ? 10 : rank), screen: _screenAutomation, favorites: _favorites);
          if (q.isNotEmpty) noteYoutubeQuery(q);
          break;

        case 'play_favorite':
          result = await _youtube.playFavorite(favorites: _favorites, screen: _screenAutomation);
          break;

        case 'play_netflix':
          final title = _s(p['title'] ?? p['query'] ?? p['show']);
          result = await _netflix.play(
            title,
            screen: _screenAutomation,
            appLauncher: _appLauncher,
            shizuku: _shizuku,
            aiService: aiService,
            favorites: _netflixFavorites,
            onProgress: onProgress,
          );
          break;

        case 'play_favorite_netflix':
          result = await _netflix.playFavorite(
            favorites: _netflixFavorites,
            screen: _screenAutomation,
            appLauncher: _appLauncher,
            shizuku: _shizuku,
            aiService: aiService,
            onProgress: onProgress,
          );
          break;

        case 'send_whatsapp':
          await PeopleBook.instance.load();
          var waContact = _s(p['contact'] ?? p['to'] ?? p['phone']);
          final waPerson = PeopleBook.instance.resolve(waContact);
          if (waPerson != null) waContact = waPerson.phone.isNotEmpty ? waPerson.phone : (waPerson.contact.isNotEmpty ? waPerson.contact : waContact);
          final waMessage = _s(p['message']);
          result = await _whatsapp.send(waContact, waMessage, contacts: _contacts, screen: _screenAutomation);
          if (result.startsWith(kWhatsappFallbackPrefix)) {
            if (aiService == null) {
              result = 'Could not send it the fast way (${result.substring(kWhatsappFallbackPrefix.length).trim()}), and no AI service is available to fall back to.';
              break;
            }
            onProgress?.call('Fast path did not work (${result.substring(kWhatsappFallbackPrefix.length).trim()}) — falling back to full navigation…');
            _currentExecutor = TaskExecutor(
              aiService: aiService,
              screenService: _screenAutomation,
              appLauncher: _appLauncher,
              shizukuService: _shizuku,
              onProgress: onProgress,
            );
            result = await _currentExecutor!.executeTask(
              'Open WhatsApp, open the chat with "$waContact" (search for them if needed), and send this exact message: $waMessage',
            );
            _currentExecutor = null;
          }
          if (!_failed.hasMatch(result.trim())) {
            unawaited(PeopleBook.instance.noteUse(waPerson?.contact.isNotEmpty == true ? waPerson!.contact : waContact, 'WhatsApp'));
          }
          break;

        case 'call_and_talk':
          await PeopleBook.instance.load();
          var ctWho = _s(p['contact'] ?? p['contact_name'] ?? p['to'] ?? p['phone_number'] ?? p['phone']);
          final ctPerson = PeopleBook.instance.resolve(ctWho);
          var ctLabel = ctWho;
          if (ctPerson != null) {
            if (ctPerson.contact.isNotEmpty) ctLabel = ctPerson.contact;
            ctWho = ctPerson.phone.isNotEmpty ? ctPerson.phone : (ctPerson.contact.isNotEmpty ? ctPerson.contact : ctWho);
          }
          final ctBrief = _s(p['brief'] ?? p['goal'] ?? p['task'] ?? p['message']);
          final ctApp = _s(p['app'], 'whatsapp').toLowerCase();
          if (ctWho.isEmpty) {
            result = 'Who should I call?';
          } else if (ctBrief.isEmpty) {
            result = 'What should I say or get done on the call?';
          } else if (aiService == null) {
            result = 'Cannot talk on a call: no AI service is available.';
          } else if (RegExp(r'phone|sim|cell|normal|regular|dialer').hasMatch(ctApp)) {
            result = 'Cannot talk on a normal phone call: the audio cable only works with WhatsApp or Telegram calls. Ask me to call them on WhatsApp instead.';
          } else if (!(await Permission.microphone.request()).isGranted) {
            result = 'Cannot start talk mode: the microphone permission is needed.';
          } else {
            final session = CallTalkSession(
              aiService: aiService,
              brief: ctBrief,
              opening: _s(p['opening']),
              who: ctLabel,
            );
            onProgress?.call('Setting up the virtual audio cable…');
            // The cable must be in place BEFORE the call app opens its microphone.
            await session.prepare();
            final appLabel = ctApp.contains('telegram') ? 'Telegram' : 'WhatsApp';

            // The agent drives the app like a person would: open it, open the chat, tap the call button.
            onProgress?.call('Opening $appLabel to call $ctLabel…');
            _currentExecutor = TaskExecutor(
              aiService: aiService,
              screenService: _screenAutomation,
              appLauncher: _appLauncher,
              shizukuService: _shizuku,
              onProgress: onProgress,
            );
            final navResult = await _currentExecutor!.executeTask(
              'Open $appLabel, open the chat with "$ctWho" (search for them if needed) and start a VOICE call to them '
              '(tap the phone / "Voice call" button; if a dialog asks to confirm the call, confirm it). '
              'Do not send any message. Finish as soon as the call screen (ringing / calling) is showing.',
            );
            _currentExecutor = null;

            // Talk mode starts by itself the moment the call is up. If the agent
            // could not tap through, the user may still place the call by hand.
            onProgress?.call('Waiting for the call to start…');
            final navFailed = _failed.hasMatch(navResult.trim());
            final started = await CallTalkSession.waitForCall(timeout: Duration(seconds: navFailed ? 75 : 40));
            if (!started) {
              await session.stop();
              result = navFailed
                  ? 'Could not place the call ($navResult), and no call started on its own.'
                  : 'Could not tell that a call started, so talk mode is off. Say it again once the call is ringing, or start "Talk on my call" yourself.';
              break;
            }
            unawaited(PeopleBook.instance.noteUse(ctLabel, '$appLabel call'));
            await session.start();
            result = 'On the call with $ctLabel ($appLabel) — talk mode is on'
                '${session.cableOn ? '' : ' (virtual cable unavailable: ${CableService.instance.lastError}; put the call on speaker)'}.';
          }
          break;

        case 'app_assist':
          {
            if (aiService == null) {
              result = 'Cannot start the app assistant: no AI service is available.';
              break;
            }
            final problem = await AssistService.instance.start(
              aiService,
              this,
              app: _s(p['app'] ?? p['app_name']),
              request: _s(p['request'] ?? p['task'] ?? p['goal']),
            );
            result = problem ?? 'The app assistant is on and I am helping in the app. Say "close assistant" when you are done.';
            if (problem != null) result = 'Cannot start the app assistant: $problem';
          }
          break;

        case 'delegate_ai':
          {
            final dPrompt = _s(p['prompt'] ?? p['task'] ?? p['goal'] ?? p['request']);
            if (dPrompt.isEmpty) {
              result = 'What should I ask it to make?';
            } else if (aiService == null) {
              result = 'Cannot hand this over: no AI service is available.';
            } else {
              result = await AiDelegateService().send(
                target: _s(p['target'] ?? p['app'], 'claude'),
                prompt: dPrompt,
                ai: aiService,
                screen: _screenAutomation,
                launcher: _appLauncher,
                shizuku: _shizuku,
                onProgress: onProgress,
              );
            }
          }
          break;

        case 'take_photo':
          result = await _camera.takePhoto(selfie: _s(p['camera']).toLowerCase() == 'front' || _s(p['camera']).toLowerCase() == 'selfie');
          break;

        case 'take_selfie':
          result = await _camera.takePhoto(selfie: true);
          break;

        case 'analyze_photo':
          result = await LabVision.instance.analyzeImage(
            _sn(p['path']) ?? _camera.lastPhotoPath,
            _s(p['question'] ?? p['query']),
            ai: aiService,
          );
          break;

        case 'send_ir':
          {
            final raw = p['names'] ?? p['commands'] ?? p['name'];
            final List<String> list = raw is List
                ? raw.map((e) => '$e').toList()
                : _s(raw).split(RegExp(r'\s*(?:,|;|\|)\s*|\s+then\s+', caseSensitive: false));
            result = await _ir.sendMany(list);
          }
          break;

        case 'save_ir':
          final rawPattern = p['pattern'];
          List<int> pattern = const [];
          if (rawPattern is List) {
            pattern = rawPattern.map((e) => asInt(e) ?? 0).toList();
          } else if (rawPattern is String) {
            pattern = rawPattern.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).map((e) => asInt(e) ?? 0).toList();
          }
          result = await _ir.save(_s(p['name']), asInt(p['frequency']) ?? 38000, pattern);
          break;

        case 'analyze_screen':
          result = await LabVision.instance.analyze(
            _s(p['question'] ?? p['query']),
            screen: _screenAutomation,
            launcher: _appLauncher,
            ai: aiService,
          );
          break;

        case 'run_taught':
          final tvars = <String, dynamic>{};
          final rawVars = p['vars'] ?? p['variables'];
          if (rawVars is Map) {
            rawVars.forEach((k, v) => tvars['$k'] = v);
          }
          result = await LabTeach.instance.run(
            _s(p['name']),
            tvars,
            screen: _screenAutomation,
            launcher: _appLauncher,
            onProgress: onProgress,
          );
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
    LabTeach.instance.cancel();
  }
}
