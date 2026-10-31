import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../agent/llm_client.dart';
import '../agent/prefs.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'call_background.dart';
import 'task_executor.dart';
import 'voice_service.dart';

/// "Special app assistance": a voice-driven assistant that rides along in any
/// app, like the "Talk to the agent" call but inside the app you are using.
///
/// You talk, it answers out loud and does things in the app. A small status
/// pill shows what it is doing; a BIG card pops up over the app only when it
/// talks about content (a price, a rating, a subscriber count...).
///
/// Buying asks twice — when the risky task starts and again at checkout —
/// answered by voice or by tapping the card, unless "autonomous" is on.
class AssistService {
  AssistService._();
  static final AssistService instance = AssistService._();

  static const MethodChannel _ch = MethodChannel('com.privateagent/assist');
  static const String _own = 'com.orailnoor.privateagent';

  late AiService _ai;
  late ActionHandler _actions;
  final VoiceService _voice = VoiceService();
  TaskExecutor? _executor;
  Timer? _poll;
  bool active = false;
  bool _working = false;
  String _pkg = '';
  String _appLabel = '';
  String _kind = 'generic';
  String _candidate = '';
  String _pendingRequest = '';
  DateTime _lastHeard = DateTime.now();
  Completer<bool>? _confirmC;

  // ── Which kind of app is this? ───────────────────────────────────────────

  static const Map<String, List<String>> _kinds = {
    'shopping': ['amazon.mshop', 'amazon.in', 'flipkart', 'myntra', 'meesho', 'ajio', 'nykaa', 'snapdeal', 'tatacliq', 'bigbasket', 'blinkit', 'zepto', 'jiomart', 'ebay', 'aliexpress', 'shopee', 'lazada', 'walmart', 'etsy', 'olx'],
    'food': ['swiggy', 'zomato', 'dominos', 'mcdonalds', 'eatsure', 'ubereats', 'doordash'],
    'video': ['youtube', 'netflix', 'amazon.avod', 'hotstar', 'jiocinema', 'sonyliv', 'zee5', 'primevideo'],
    'social': ['instagram', 'twitter', 'facebook', 'reddit', 'linkedin', 'snapchat', 'threads', 'x.android'],
    'music': ['spotify', 'gaana', 'jiosaavn', 'wynk'],
    'maps': ['apps.maps', 'ola', 'uber', 'rapido'],
  };

  static const Map<String, String> _names = {
    'amazon': 'Amazon', 'flipkart': 'Flipkart', 'myntra': 'Myntra', 'meesho': 'Meesho', 'ajio': 'Ajio', 'nykaa': 'Nykaa',
    'blinkit': 'Blinkit', 'zepto': 'Zepto', 'swiggy': 'Swiggy', 'zomato': 'Zomato', 'youtube': 'YouTube', 'netflix': 'Netflix',
    'hotstar': 'Hotstar', 'instagram': 'Instagram', 'twitter': 'X', 'facebook': 'Facebook', 'reddit': 'Reddit',
    'linkedin': 'LinkedIn', 'spotify': 'Spotify', 'maps': 'Maps', 'jiomart': 'JioMart', 'bigbasket': 'BigBasket',
  };

  static String kindOf(String pkg) {
    final p = pkg.toLowerCase();
    for (final e in _kinds.entries) {
      if (e.value.any(p.contains)) return e.key;
    }
    return 'generic';
  }

  static String nameOf(String pkg) {
    final p = pkg.toLowerCase();
    for (final e in _names.entries) {
      if (p.contains(e.key)) return e.value;
    }
    final last = pkg.split('.').last;
    return last.isEmpty ? pkg : '${last[0].toUpperCase()}${last.substring(1)}';
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Starts the assistant. [app] (a name) is opened first when given, and
  /// [request] is carried out as soon as that app is in front. Returns an
  /// error message, or null when it started.
  Future<String?> start(AiService ai, ActionHandler actions, {String app = '', String request = ''}) async {
    if (active) return null;
    _ai = ai;
    _actions = actions;
    if (!await CallBackground.overlayGranted()) {
      await CallBackground.requestOverlay();
      return 'Allow "Display over other apps" for PrivateAgent, then ask again.';
    }
    if (!(await Permission.microphone.request()).isGranted) {
      return 'The microphone permission is needed so you can talk to the assistant.';
    }
    await AgentPrefs.instance.load();
    await _voice.init();
    _ch.setMethodCallHandler(_fromNative);
    active = true;
    _working = false;
    _pkg = '';
    _candidate = '';
    _pendingRequest = request.trim();
    _lastHeard = DateTime.now();
    // A foreground service keeps the assistant alive while other apps are open.
    await CallBackground.start('App assistant is on — tap Hang up to close it', phase: 'listening');
    CallBackground.onHangup(stop);
    await _ch.invokeMethod('show');
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) => _watchForeground());

    if (app.trim().isNotEmpty) {
      await _state('acting', 'Opening ${app.trim()}…');
      await _actions.appLauncher.openApp(app.trim());
    } else {
      await _state('pick', 'Open the app you want help with');
      unawaited(_voice.speak('Open the app you want help with, then tell me what you need.'));
      await CallBackground.minimize();
    }
    unawaited(_loop());
    return null;
  }

  Future<void> stop() async {
    if (!active) return;
    active = false;
    _poll?.cancel();
    _poll = null;
    _executor?.cancel();
    _executor = null;
    final c = _confirmC;
    if (c != null && !c.isCompleted) c.complete(false);
    unawaited(_voice.stopListening());
    unawaited(_voice.stopSpeaking());
    try {
      await _ch.invokeMethod('hide');
    } catch (_) {}
    CallBackground.onHangup(null);
    await CallBackground.stop();
  }

  // ── Watching which app is in front ───────────────────────────────────────

  static bool _ignorable(String pkg) {
    final p = pkg.toLowerCase();
    return p.isEmpty ||
        p == _own ||
        p.contains('systemui') ||
        p.contains('launcher') ||
        p.contains('inputmethod') ||
        p.contains('keyboard') ||
        p == 'android';
  }

  Future<void> _watchForeground() async {
    if (!active || _working) return;
    final pkg = await _actions.screenAutomation.getCurrentPackage() ?? '';
    if (_ignorable(pkg) || pkg == _pkg) return;
    // Seen twice in a row = the user really switched to it.
    if (pkg != _candidate) {
      _candidate = pkg;
      return;
    }
    _pkg = pkg;
    _kind = kindOf(pkg);
    _appLabel = nameOf(pkg);
    await _listeningState();
  }

  Future<void> _state(String mode, String text) async {
    try {
      await _ch.invokeMethod('state', {'mode': mode, 'text': text, 'chips': const <Map<String, String>>[]});
    } catch (_) {}
  }

  Future<void> _listeningState() => _state('panel', 'Listening — ask me about $_appLabel');

  Future<void> _big(String label, String value, String sub, {int ms = 9000}) async {
    try {
      await _ch.invokeMethod('big', {'label': label, 'value': value, 'sub': sub, 'ms': ms});
    } catch (_) {}
  }

  Future<dynamic> _fromNative(MethodCall call) async {
    switch (call.method) {
      case 'close':
        await stop();
        break;
      case 'confirm':
        final c = _confirmC;
        if (c != null && !c.isCompleted) c.complete((call.arguments as Map)['value'] == true);
        break;
    }
    return null;
  }

  // ── The voice loop ───────────────────────────────────────────────────────

  static final RegExp _exit = RegExp(
    r"\b(close( the)? assistant|exit|stop assistant|that's all|thats all|that is all|i'm done|im done|goodbye|bye|band karo|bas|thank you|thanks)\b",
    caseSensitive: false,
  );

  Future<void> _loop() async {
    while (active) {
      if (_pkg.isEmpty || _working) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (_pkg.isEmpty && DateTime.now().difference(_lastHeard) > const Duration(minutes: 4)) {
          await stop();
        }
        continue;
      }
      // A request handed over with the app (e.g. "buy earbuds on Amazon").
      if (_pendingRequest.isNotEmpty) {
        final r = _pendingRequest;
        _pendingRequest = '';
        _lastHeard = DateTime.now();
        await _handle(r);
        continue;
      }
      await _listeningState();
      final heard = await _voice.listenOnce(
        maxSpeech: const Duration(seconds: 20),
        endSilence: const Duration(milliseconds: 1200),
        noSpeechTimeout: const Duration(seconds: 60),
      );
      if (!active) break;
      final text = (heard ?? '').trim();
      if (text.isEmpty) {
        if (DateTime.now().difference(_lastHeard) > const Duration(minutes: 3)) {
          await _say('I will close the assistant now. Tap the assistant button when you need me again.');
          await stop();
        }
        continue;
      }
      _lastHeard = DateTime.now();
      if (_exit.hasMatch(text) && text.split(RegExp(r'\s+')).length <= 6) {
        await _say('Okay, closing the assistant.');
        await stop();
        break;
      }
      await _handle(text);
    }
  }

  /// Speaks and waits, so the loop never listens to its own voice.
  Future<void> _say(String text) async {
    if (text.trim().isEmpty) return;
    await _voice.stopListening();
    await _voice.speakAndWait(text);
  }

  Future<void> _handle(String text) async {
    if (!active) return;
    _working = true;
    try {
      await _command(text);
    } catch (e) {
      await _big('Problem', '—', e.toString(), ms: 6000);
      await _say('Sorry, something went wrong.');
    } finally {
      _working = false;
      if (active) await _listeningState();
    }
  }

  Future<void> _command(String heard) async {
    final t = heard.toLowerCase();
    bool has(String pattern) => RegExp(pattern).hasMatch(t);
    if (has(r'\b(buy|order|checkout|check out|purchase|khareed|kharid|mangwa)\b')) return _buy(heard);
    if (has(r'\b(price|cost|kitna|kitne|daam|dam|kimat|how much)\b')) {
      await _read('Price', 'the current price of the item on screen (with any discount or MRP in sub)');
      return;
    }
    if (has(r'\b(rating|ratings|stars?)\b')) {
      await _read('Rating', 'the star rating and number of ratings of the item/place on screen');
      return;
    }
    if (has(r'subscriber')) {
      await _read('Subscribers', 'the subscriber count of the channel shown (value = count like 1.2M)');
      return;
    }
    if (has(r'\b(views?|likes?|followers?)\b') && !has(r'\b(open|go|scroll|tap|click|play)\b')) {
      await _read('Stats', 'the key numbers on screen: views and likes for a video, or followers/following/posts for a profile (value = the most important one)');
      return;
    }
    if (has(r'\b(reviews?)\b') && !has(r'\b(open|go|scroll|tap|click)\b')) {
      await _read('Reviews', 'a one-line summary of what reviewers say (pros and cons); value = overall rating');
      return;
    }
    if (has(r"^(what|which|who|how|is|are|does|do|can|kya|kaun|kaisa|batao|tell|explain|summar)") || t.endsWith('?')) {
      await _read('Answer', 'the answer to this question: "$heard" (value = the short answer, sub = one helpful line)');
      return;
    }
    // Anything else is an instruction: the screen agent does it.
    final result = await _act(heard);
    await _say(result.length > 220 ? result.substring(0, 220) : result);
  }

  // ── Reading the screen ───────────────────────────────────────────────────

  Future<String> _screenText() async {
    final t = await _actions.screenAutomation.getScreenDescription();
    return t.length > 7000 ? t.substring(0, 7000) : t;
  }

  Map<String, dynamic>? _json(String s) {
    final a = s.indexOf('{');
    final b = s.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final j = jsonDecode(s.substring(a, b + 1));
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// Reads [what] off the current screen, then shows it BIG and says it aloud.
  Future<Map<String, dynamic>?> _read(String label, String what, {bool speak = true, bool retryScroll = true}) async {
    await _state('acting', 'Reading the screen…');
    var screen = await _screenText();
    var j = await _extract(what, screen);
    final missing = j == null || (j['value']?.toString().trim() ?? '—') == '—' || j['value'].toString().trim().isEmpty;
    if (missing && retryScroll) {
      // The number is often just below the fold.
      await _actions.screenAutomation.scroll('down');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      screen = await _screenText();
      j = await _extract(what, screen) ?? j;
    }
    if (j == null) {
      if (speak) {
        await _big(label, '—', 'I could not read that on this screen.', ms: 6000);
        await _say('I could not find that on this screen.');
      }
      return null;
    }
    final value = j['value']?.toString().trim() ?? '—';
    final sub = j['sub']?.toString().trim() ?? '';
    final shownLabel = (j['label']?.toString().trim().isNotEmpty ?? false) ? j['label'].toString().trim() : label;
    if (speak) {
      // The big card appears at the moment the agent starts talking about it.
      await _big(shownLabel, value, sub, ms: 12000);
      await _say(value == '—' ? 'I could not find that on this screen.' : '$shownLabel: $value. $sub'.trim());
    }
    return j;
  }

  Future<Map<String, dynamic>?> _extract(String what, String screen) async {
    try {
      final r = await LlmClient(_ai).complete(
        [
          {
            'role': 'system',
            'content': 'You read the text dump of a phone screen. Task: find $what. '
                'Reply ONLY with JSON {"label": short title, "value": the answer, very short (e.g. "₹1,499", "4.3 ★", "1.2M"), '
                '"sub": one short helpful line or ""}. If it is not on the screen use value "—". Never invent numbers.',
          },
          {'role': 'user', 'content': 'App: $_appLabel\nSCREEN:\n$screen'},
        ],
        temperature: 0.1,
        maxTokens: 160,
      );
      return _json(r.content);
    } catch (_) {
      return null;
    }
  }

  Future<String> _act(String goal) async {
    await _state('acting', 'Working on it…');
    _executor = TaskExecutor(
      aiService: _ai,
      screenService: _actions.screenAutomation,
      appLauncher: _actions.appLauncher,
      shizukuService: _actions.shizuku,
      onProgress: (m) => unawaited(_state('acting', m)),
    );
    final result = await _executor!.executeTask('In the app that is currently open ($_appLabel): $goal');
    _executor = null;
    return result;
  }

  // ── Buying (two confirmations) ───────────────────────────────────────────

  static final RegExp _yes = RegExp(r"\b(yes|yeah|yep|yup|ok|okay|sure|confirm|go ahead|do it|proceed|haan|han|ha|haa|kar do|karo|theek|thik)\b");
  static final RegExp _no = RegExp(r"\b(no|nope|cancel|stop|don't|dont|nahi|nahin|nai|mat|ruko|ruk)\b");

  /// Asks by voice AND by the card's buttons; the first answer wins. No answer = no.
  Future<bool> _confirm(String question) async {
    if (AgentPrefs.instance.assistAutonomous) return true;
    final c = _confirmC = Completer<bool>();
    await _ch.invokeMethod('confirm', {'text': question});
    unawaited(() async {
      await _voice.speakAndWait(question);
      while (!c.isCompleted && active) {
        final heard = await _voice.listenOnce(
          maxSpeech: const Duration(seconds: 6),
          endSilence: const Duration(milliseconds: 900),
          noSpeechTimeout: const Duration(seconds: 10),
        );
        if (c.isCompleted) return;
        final t = (heard ?? '').toLowerCase();
        if (t.isEmpty) continue;
        if (_no.hasMatch(t)) {
          c.complete(false);
        } else if (_yes.hasMatch(t)) {
          c.complete(true);
        }
      }
    }());
    final answer = await c.future.timeout(const Duration(seconds: 60), onTimeout: () => false);
    _confirmC = null;
    try {
      await _ch.invokeMethod('clearConfirm');
    } catch (_) {}
    await _voice.stopListening();
    return answer;
  }

  static final RegExp _buyWords = RegExp(
    r"\b(buy|order|purchase|checkout|check out|khareed|kharid|mangwa|this|it|please|for me|now|do|kar|karo|isse|ise|de|dena|mujhe|me)\b",
    caseSensitive: false,
  );

  Future<void> _buy(String request) async {
    // What to find first ("wireless earbuds under 2000"), if the user named one.
    final wanted = request.replaceAll(_buyWords, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final named = wanted.length > 5 && !RegExp(r'^(on|in|from)\s+\w+$', caseSensitive: false).hasMatch(wanted);

    // Confirmation 1: this task is risky.
    final what = named ? '"$wanted"' : 'this item';
    if (!await _confirm('This is a risky task. I will ${named ? 'find $what, ' : ''}tap Buy Now and go to checkout. Continue?')) {
      await _big('Cancelled', '✋', 'I did not buy anything.', ms: 4000);
      await _say('Okay, I did not buy anything.');
      return;
    }
    if (named) {
      await _act('Search for $what in this app and open the best matching product (good rating, within any budget mentioned).');
    }
    final nav = await _act(
      'On this product page keep the default options (size/colour/quantity), tap "Buy Now" (or "Add to cart" and then "Proceed to checkout"). '
      'Stop as soon as the order summary / payment screen is showing. Do NOT place the order and do NOT pay.',
    );
    final total = await _read('Order total', 'the total amount payable on this checkout screen and the delivery address/date (value = total, sub = delivery info)', speak: false, retryScroll: false);
    final amount = total?['value']?.toString() ?? '—';
    if (amount == '—') {
      await _big('Checkout', '⚠', 'I could not reach a checkout screen.', ms: 7000);
      await _say('I could not reach the checkout screen. ${nav.length > 160 ? nav.substring(0, 160) : nav}');
      return;
    }

    // Confirmation 2: at checkout. The total pops up big while it is asked.
    await _big('Total payable', amount, total?['sub']?.toString() ?? '', ms: 20000);
    if (!await _confirm('Checkout is ready. The total is $amount. Place the order now?')) {
      await _big('Stopped at checkout', amount, 'The order was NOT placed. You can finish it yourself.', ms: 7000);
      await _say('Okay, I stopped at checkout and did not place the order.');
      return;
    }
    final done = await _act(
      'Tap the final "Place order" / "Pay" / "Confirm order" button on this checkout screen. '
      'If a PIN, OTP or fingerprint screen appears, stop there and say so.',
    );
    await _big('Order', '✓', done.length > 160 ? done.substring(0, 160) : done, ms: 8000);
    await _say(done.length > 220 ? done.substring(0, 220) : done);
  }
}
