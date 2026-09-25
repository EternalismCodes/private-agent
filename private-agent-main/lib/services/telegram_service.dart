import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../agent/agent_context.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_mode.dart';
import '../models/chat_message.dart';
import '../agent/scheduler_service.dart';

/// Lets the phone be controlled remotely from a Telegram chat.
///
/// Messages are routed through the same [AgentController] the app itself
/// uses (Auto mode, unattended), so Telegram gets everything the app does:
/// multi-step tasks, learned workflows and templates, skills, memory and
/// scheduling — not just the handful of one-shot device actions this used to
/// be limited to.
///
/// Reliability: polling runs on a `Timer` in the main engine's Dart isolate,
/// which Android will happily freeze once the app is backgrounded unless
/// something keeps the process alive. A small foreground service (started
/// here, see [TelegramBridge]) does exactly that for as long as the
/// integration is enabled, so replies keep coming while the screen is off or
/// another app is open — the entire point of a *remote* control channel.
class TelegramService {
  final AgentContext _ctx;
  late final AgentController _controller = AgentController(_ctx);

  String _botToken = '';
  bool _isEnabled = false;
  int _lastUpdateId = 0;
  bool _isPolling = false;
  Timer? _pollingTimer;
  String _activeChatId = '';

  /// Last few status lines, for a simple diagnostics view in Settings.
  final List<String> log = [];
  void Function()? onLog;

  TelegramService(this._ctx);

  String get botToken => _botToken;
  bool get isEnabled => _isEnabled;

  void _log(String line) {
    log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (log.length > 30) log.removeRange(30, log.length);
    onLog?.call();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString('telegram_bot_token') ?? '';
    _isEnabled = prefs.getBool('telegram_enabled') ?? false;

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    }
  }

  Future<void> saveSettings({required String botToken, required bool isEnabled}) async {
    _botToken = botToken;
    _isEnabled = isEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('telegram_bot_token', _botToken);
    await prefs.setBool('telegram_enabled', _isEnabled);

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    } else {
      stopPolling();
    }
  }

  void startPolling() {
    TelegramBridge.start();
    if (_isPolling) return;
    _isPolling = true;
    _log('Started listening for Telegram messages');
    _pollUpdates();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
    TelegramBridge.stop();
  }

  Future<void> _pollUpdates() async {
    if (!_isPolling || _botToken.isEmpty) return;

    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/getUpdates');
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'offset': _lastUpdateId + 1,
              'timeout': 25, // Long polling timeout, must stay under the client timeout below
              'allowed_updates': ['message'],
            }),
          )
          .timeout(const Duration(seconds: 35));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final results = data['result'] as List;
          for (final update in results) {
            _lastUpdateId = update['update_id'];
            if (update['message'] != null && update['message']['text'] != null) {
              final text = update['message']['text'] as String;
              final chatId = update['message']['chat']['id'];
              unawaited(_handleIncomingMessage(chatId.toString(), text));
            }
          }
        } else {
          _log('Telegram API error: ${data['description'] ?? data['error_code']}');
        }
      } else if (response.statusCode == 401) {
        _log('Bot token rejected (401) — check it in Settings');
        stopPolling();
        return;
      } else {
        _log('Telegram poll HTTP ${response.statusCode}');
      }
    } on TimeoutException {
      // Normal for long polling with nothing new; just poll again.
    } catch (e) {
      _log('Telegram polling error: $e');
    }

    // Continue polling
    if (_isPolling) {
      _pollingTimer = Timer(const Duration(milliseconds: 800), _pollUpdates);
    }
  }

  Future<void> _handleIncomingMessage(String chatId, String text) async {
    final cmd = text.trim().toLowerCase();
    if (cmd == '/stop' || cmd == 'stop') {
      _controller.cancel();
      await _sendMessage(chatId, '🛑 Stopped.');
      return;
    }
    if (cmd == '/status') {
      await _sendMessage(chatId, _controller.busy ? '⏳ Working on a request.' : '✅ Idle and listening.');
      return;
    }
    if (cmd == '/start' || cmd == '/help') {
      await _sendMessage(chatId,
          '🤖 Send any request (e.g. "open WhatsApp and message Sam hi", "set a 10 minute timer", "weather in Paris").\n/stop cancels the current job, /status shows what I am doing.\nThe phone must be unlocked for me to control other apps.');
      return;
    }
    if (_controller.busy) {
      await _sendMessage(chatId, '🤖 Still working on the previous request — try again in a moment.');
      return;
    }

    await _sendMessage(chatId, '🤖 Got it: "$text". Working on it…');
    _log('▶ $text');
    _activeChatId = chatId;

    // Wake the screen and, if allowed, bring the app forward — Android
    // blocks a backgrounded app from opening other apps or driving the
    // screen otherwise. Harmless no-op without the overlay permission.
    await SchedulerService.instance.wakeForRemote(text);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    try {
      final result = await _controller.handle(text, AgentMode.auto, _telegramUi(chatId), unattended: true);
      final prefix = result.success ? '✅' : '⚠️';
      final reply = result.reply.trim().isEmpty ? 'Done.' : result.reply.trim();
      await _sendMessage(chatId, '$prefix $reply');
      _log('${result.success ? "✔" : "✘"} $text');
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      await _sendMessage(chatId, '❌ Error: $message');
      _log('✘ $text — $message');
    } finally {
      unawaited(SchedulerService.instance.releaseWake());
    }
  }

  AgentUi _telegramUi(String chatId) => AgentUi(
        // No chat UI to update; the controller just needs somewhere to write.
        addMessage: (m) => m,
        refresh: () {},
        removeMessage: (m) {},
        // Telegram runs unattended, so confirmStep is never actually invoked.
        confirmStep: (step) async => true,
        onProgress: (msg) {
          if (chatId == _activeChatId) unawaited(_sendMessage(chatId, '⏳ $msg'));
        },
      );

  Future<void> _sendMessage(String chatId, String text) async {
    if (_botToken.isEmpty) return;
    final trimmed = text.length > 3900 ? '${text.substring(0, 3900)}…' : text;
    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/sendMessage');
      await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'chat_id': chatId, 'text': trimmed}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      _log('Failed to send reply: $e');
    }
  }

  void dispose() {
    stopPolling();
  }
}

/// Native side: a small foreground service that keeps this process (and so
/// the Dart polling timer above) alive while Telegram is enabled.
class TelegramBridge {
  TelegramBridge._();
  static const _channel = MethodChannel('com.privateagent/telegram_service');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
