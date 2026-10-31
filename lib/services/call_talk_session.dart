import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../agent/llm_client.dart';
import '../agent/prefs.dart';
import 'ai_service.dart';
import 'cable_service.dart';
import 'call_background.dart';
import 'call_ears.dart';
import 'notification_service.dart';
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'tts_voices.dart';
import 'voice_service.dart';

class TalkLine {
  final bool me;
  final String text;
  const TalkLine(this.me, this.text);
}

/// "Talk on my call": while a WhatsApp/Telegram call is running, the agent
/// speaks AS the user, following a short brief, and answers what the other
/// person says.
///
/// Speaking: through the virtual cable (straight into the call app's
/// microphone) when it could be started, otherwise through the loudspeaker.
/// Hearing: the phone's own live captions (switched on automatically when
/// Shizuku allows it), falling back to the microphone.
///
/// Built for speed: the reply streams from the model and is spoken sentence
/// by sentence while it is still being written; the prompt is minimal.
///
/// With "Full automation" on it also stalls with short fillers while the model
/// is slow, hangs up when the brief is done, and reports on the call.
class CallTalkSession extends ChangeNotifier {
  static CallTalkSession? current;

  /// The summary of the most recent call, for the Talk screen.
  static String lastReport = '';

  final AiService aiService;
  final String brief;
  final String opening;
  final String who;

  /// How long to wait for the other person to speak first before saying
  /// [opening] anyway.
  final Duration openingWait;

  CallTalkSession({
    required this.aiService,
    required this.brief,
    this.opening = '',
    this.who = '',
    this.openingWait = const Duration(seconds: 20),
  });

  static const MethodChannel _audio = MethodChannel('com.privateagent/audioprobe');
  static const double _callRate = 0.56; // a touch quicker than the default
  static const _captionKey = 'odi_captions_enabled';

  final VoiceService _voice = VoiceService();
  LlmClient? _llmClient;
  final List<TalkLine> lines = [];
  final List<String> _pending = [];
  CaptionEars? _ears;
  Timer? _callWatch;
  bool active = false;
  bool _prepared = false;
  bool _busy = false;
  bool _usingMic = false;
  bool _openingSaid = false;
  bool _automation = false;
  bool _hindi = false;
  bool cableOn = false;
  String status = '';
  String cableNote = '';
  String _lastSpoken = '';
  String? _captionBefore;
  DateTime _startedAt = DateTime.now();
  DateTime _lastActivity = DateTime.now(); // last time either side spoke
  DateTime _busySince = DateTime.now();
  int _turn = 0; // bumped when a stuck turn is abandoned
  int _nudges = 0;
  bool _heardAny = false;

  /// Finished call reports; the chat screen listens and posts them as a message.
  static final StreamController<String> reportStream = StreamController<String>.broadcast();

  void _set(String s) {
    status = s;
    notifyListeners();
  }

  /// A dedicated talk-mode key/model when set in settings, else the main provider.
  LlmClient get _llm => _llmClient ??= LlmClient(_talkService());

  AiService _talkService() {
    final p = AgentPrefs.instance;
    if (p.talkApiKey.trim().isEmpty) return aiService;
    return AiService.dedicated(
      apiKey: p.talkApiKey,
      baseUrl: p.talkBaseUrl.trim().isEmpty ? aiService.primaryBaseUrl : p.talkBaseUrl,
      model: p.talkModel.trim().isEmpty ? aiService.primaryModel : p.talkModel,
    );
  }

  /// True while a WhatsApp/Telegram-style call is up: Android puts the audio
  /// system in "communication" mode (3) — or "in call" (2) — for it.
  static Future<bool> inCall() async {
    try {
      final st = await _audio.invokeMethod<Map>('audioState');
      final mode = (st?['mode'] as num?)?.toInt() ?? 0;
      return mode == 3 || mode == 2;
    } catch (_) {
      return false;
    }
  }

  /// Polls until a call is up (true) or [timeout] passes (false).
  static Future<bool> waitForCall({Duration timeout = const Duration(seconds: 40)}) async {
    final end = DateTime.now().add(timeout);
    var seen = 0;
    while (DateTime.now().isBefore(end)) {
      if (await inCall()) {
        // Two readings in a row, so a brief mode flicker doesn't count.
        if (++seen >= 2) return true;
      } else {
        seen = 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// Brings the virtual cable up and the live captions on. Do this BEFORE the
  /// call is placed: the call app picks its microphone source when it starts.
  Future<void> prepare() async {
    if (_prepared) return;
    _prepared = true;
    await AgentPrefs.instance.load();
    _set('Setting up the virtual audio cable…');
    final captions = _enableCaptions();
    cableOn = await CableService.instance.start();
    await captions;
    cableNote = cableOn
        ? 'Virtual cable on: my voice goes straight into the call.'
        : 'Virtual cable unavailable (${CableService.instance.lastError}) — I will speak through the loudspeaker instead.';
    _set(cableNote);
  }

  /// Best effort: switch the system live captions on (Android "Live Caption").
  /// Phone makers with their own captioning app (Xiaomi AI Subtitles) may
  /// ignore this; then switch theirs on once by hand.
  Future<void> _enableCaptions() async {
    try {
      final sh = ShizukuService();
      if (!await sh.checkAvailability() || !sh.hasPermission) return;
      _captionBefore = (await sh.runCommand('settings get secure $_captionKey')).trim();
      await sh.runCommand('settings put secure $_captionKey 1');
    } catch (_) {}
  }

  Future<void> _restoreCaptions() async {
    final before = _captionBefore;
    if (before == null) return;
    _captionBefore = null;
    try {
      final sh = ShizukuService();
      if (!await sh.checkAvailability() || !sh.hasPermission) return;
      if (before == '1') return; // was already on
      await sh.runCommand('settings put secure $_captionKey ${before == 'null' || before.isEmpty ? 0 : before}');
    } catch (_) {}
  }

  /// Starts talk mode (call [prepare] first when the call is not up yet).
  Future<void> start() async {
    if (active) return;
    await current?.stop();
    current = this;
    await prepare();
    await _voice.init();
    _automation = AgentPrefs.instance.talkAutomation;
    VoiceService.talkLock = true; // the agent's chat replies must not reach the call
    unawaited(_voice.stopSpeaking());
    active = true;
    _startedAt = DateTime.now();
    lines.clear();
    _pending.clear();
    _lastSpoken = '';
    _openingSaid = false;
    _heardAny = false;
    _nudges = 0;
    _lastActivity = DateTime.now();
    _busy = false;

    CallBackground.onHangup(stop);
    unawaited(CallBackground.start('Talking on your call — tap Hang up to stop', phase: 'listening'));
    _ears = CaptionEars(onHeard: _onHeard)..start();
    _set(cableNote);
    unawaited(_openingFallback());
    unawaited(_watchEars());
    _watchCall();
    _watchTurns();
  }

  /// Ends the session by itself when the other side hangs up.
  void _watchCall() {
    var gone = 0;
    _callWatch?.cancel();
    _callWatch = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!active) return;
      if (await inCall()) {
        gone = 0;
        return;
      }
      if (++gone >= 5 && DateTime.now().difference(_startedAt) > const Duration(seconds: 8)) {
        unawaited(stop(reason: 'The call ended.'));
      }
    });
  }

  Timer? _turnWatch;

  static const _nudgeEn = ['Hello?', 'Are you there?', 'Hello, can you hear me?'];
  static const _nudgeHi = ['हेलो?', 'आप सुन रहे हैं?', 'हेलो, आवाज़ आ रही है?'];

  /// Once a second: breaks awkward silences, and unsticks a turn that hung.
  void _watchTurns() {
    _turnWatch?.cancel();
    _turnWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!active) return;
      final now = DateTime.now();
      // Watchdog: a reply that has been "in progress" far too long is abandoned.
      if (_busy && now.difference(_busySince) > const Duration(seconds: 25)) {
        _turn++;
        _busy = false;
        unawaited(_voice.stopSpeaking());
        _set('Recovered from a stuck reply.');
        _lastActivity = now;
        if (_pending.isNotEmpty) unawaited(_respond());
        return;
      }
      if (_busy) return;
      // Silence breaker: nobody has spoken for ~7.5 s.
      final quietFor = now.difference(_lastActivity);
      final ready = _heardAny || now.difference(_startedAt) > const Duration(seconds: 25);
      if (ready && (_openingSaid || opening.trim().isEmpty) && quietFor > Duration(milliseconds: _nudges == 0 ? 7500 : 12000)) {
        unawaited(_breakSilence());
      }
    });
  }

  Future<void> _breakSilence() async {
    if (_busy || !active) return;
    _busy = true;
    _busySince = DateTime.now();
    final turn = ++_turn;
    try {
      if (_nudges >= 3) {
        if (_automation) {
          final bye = _hindi ? 'लगता है आवाज़ नहीं आ रही, मैं बाद में फ़ोन करता हूँ। नमस्ते।' : "I can't seem to reach you, I'll call back later. Bye.";
          lines.add(TalkLine(true, bye));
          notifyListeners();
          await _say(bye);
          if (turn == _turn) {
            await _hangUp();
            await stop(reason: 'Nobody answered or spoke, so I ended the call.');
          }
          return;
        }
        _lastActivity = DateTime.now();
        return;
      }
      final list = _hindi ? _nudgeHi : _nudgeEn;
      final line = list[_nudges % list.length];
      _nudges++;
      lines.add(TalkLine(true, line));
      notifyListeners();
      await _say(line);
    } finally {
      if (turn == _turn) _busy = false;
      _lastActivity = DateTime.now();
    }
  }

  /// If the other person never speaks first, say the opening line anyway.
  Future<void> _openingFallback() async {
    await Future<void>.delayed(openingWait);
    await _sayOpening();
  }

  Future<void> _sayOpening() async {
    if (!active || _openingSaid) return;
    _openingSaid = true;
    final o = opening.trim();
    if (o.isEmpty) return;
    lines.add(TalkLine(true, o));
    notifyListeners();
    await _say(o);
  }

  /// If no caption window shows up, fall back to hearing through the mic.
  Future<void> _watchEars() async {
    await Future<void>.delayed(const Duration(seconds: 12));
    if (!active || (_ears?.found ?? false)) return;
    _ears?.stop();
    _usingMic = true;
    _set('No live captions found — listening through the microphone instead. $cableNote');
    while (active) {
      if (_busy) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      final heard = await _voice.listenOnce(
        maxSpeech: const Duration(seconds: 20),
        endSilence: const Duration(milliseconds: 900),
        noSpeechTimeout: const Duration(seconds: 60),
      );
      if (!active) break;
      if (heard != null && heard.trim().isNotEmpty) _onHeard(heard.trim());
    }
  }

  void _onHeard(String text) {
    if (!active) return;
    // The captions can pick up our own voice (loudspeaker mode); ignore it.
    if (!cableOn && _similar(text, _lastSpoken)) return;
    _hindi = TtsVoiceCatalog.looksHindi(text);
    _heardAny = true;
    _nudges = 0;
    _lastActivity = DateTime.now();
    _pending.add(text);
    lines.add(TalkLine(false, text));
    notifyListeners();
    if (!_openingSaid && opening.trim().isNotEmpty) {
      // They spoke first (e.g. "hello"): answer with the opening line.
      _pending.clear();
      unawaited(_sayOpening());
      return;
    }
    unawaited(_respond());
  }

  static bool _similar(String a, String b) {
    if (b.isEmpty) return false;
    final wa = a.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 2).toSet();
    final wb = b.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 2).toSet();
    if (wa.isEmpty || wb.isEmpty) return false;
    return wa.intersection(wb).length / wa.length >= 0.7;
  }

  // Short on purpose: every extra token in the prompt is latency.
  String get _persona {
    final name = AgentPrefs.instance.userName.trim().isEmpty ? 'the user' : AgentPrefs.instance.userName.trim();
    final target = who.trim().isEmpty ? 'the other person' : who.trim();
    return 'You are on a phone call with $target, speaking as $name (first person). Goal: ${brief.trim()}\n'
        'Reply with ONE or TWO short spoken sentences, plain words, no markdown. Match their language (Hindi in Devanagari, else English). '
        'Their words are auto-captions and may be wrong: answer what they meant. '
        'Stay on the goal; never share passwords, OTPs or card details or agree to payments (say you will check). '
        'If sincerely asked, say you are $name\'s AI assistant. '
        'If the goal is to stall/keep them talking, or you need time: chat casually, one short sentence at a time (small talk, light questions about their day, "sorry, still checking that"), and keep it going until the goal says stop; never lie about facts. '
        'If only noise or filler, reply exactly <silent>.'
        '${_automation ? ' When the goal is done and goodbyes are said, end your last words with <end>.' : ' When the call is clearly over, say a short goodbye.'}';
  }

  static final RegExp _sentenceEnd = RegExp(r'[.!?।]["”)]?\s');

  Future<void> _respond() async {
    if (_busy || !active) return;
    _busy = true;
    _busySince = DateTime.now();
    final turn = ++_turn;
    if (_usingMic) await _voice.stopListening(); // never listen to ourselves
    var endAfter = false;
    try {
      while (_pending.isNotEmpty && active && turn == _turn) {
        _pending.clear();
        final recent = lines.length > 8 ? lines.sublist(lines.length - 8) : lines;
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': _persona},
          for (final l in recent) {'role': l.me ? 'assistant' : 'user', 'content': l.text},
        ];
        _set('Thinking…');

        // Stall with a short filler if the model is slow to start answering.
        var firstSpoken = false;
        Timer? filler;
        if (_automation) {
          filler = Timer(const Duration(milliseconds: 1400), () {
            if (firstSpoken || !active) return;
            firstSpoken = true;
            final f = _hindi
                ? const ['हम्म, एक सेकंड।', 'जी, एक मिनट।', 'अच्छा, रुकिए ज़रा।']
                : const ['Hmm, one second.', 'Okay, let me check.', 'Right, just a moment.'];
            final line = f[DateTime.now().second % f.length];
            lines.add(TalkLine(true, line));
            notifyListeners();
            _lastSpoken = line;
            unawaited(_voice.speakAndWait(line, rate: _callRate, onCall: true));
          });
        }

        var buffer = '';
        var full = '';
        var silent = false;
        final speaking = <Future<void>>[];

        void speakSentence(String s) {
          var t = s.replaceAll('<end>', '').trim();
          if (t.isEmpty) return;
          firstSpoken = true;
          filler?.cancel();
          full = full.isEmpty ? t : '$full $t';
          _lastSpoken = full;
          speaking.add(_voice.speakAndWait(t, rate: _callRate, onCall: true));
          _set('Speaking…');
        }

        try {
          await for (final d in _llm.stream(messages, temperature: 0.4, maxTokens: 110).timeout(const Duration(seconds: 12))) {
            if (!active || turn != _turn) break;
            buffer += d.content;
            if (full.isEmpty && !firstSpoken) {
              final head = buffer.trimLeft();
              if (head.startsWith('<') && head.contains('silent')) {
                silent = true;
                break;
              }
            }
            if (buffer.contains('<end>')) endAfter = true;
            Match? m;
            while ((m = _sentenceEnd.firstMatch(buffer)) != null) {
              speakSentence(buffer.substring(0, m!.end));
              buffer = buffer.substring(m.end);
            }
          }
          if (!silent && active) speakSentence(buffer);
        } catch (e) {
          filler?.cancel();
          _set('The model was slow or failed: $e');
          if (full.isEmpty && active && turn == _turn) {
            // Never go silent on someone: ask them to repeat instead.
            final line = _hindi ? 'माफ़ कीजिए, ज़रा फिर से कहेंगे?' : 'Sorry, could you say that again?';
            lines.add(TalkLine(true, line));
            notifyListeners();
            await _voice.speakAndWait(line, rate: _callRate, onCall: true).timeout(const Duration(seconds: 12), onTimeout: () {});
          }
          break;
        }
        filler?.cancel();
        if (silent || full.isEmpty && speaking.isEmpty) {
          _ears?.rebase();
          continue;
        }
        lines.add(TalkLine(true, full));
        notifyListeners();
        try {
          await Future.wait(speaking).timeout(const Duration(seconds: 25));
        } catch (_) {
          await _voice.stopSpeaking();
        }
        _lastActivity = DateTime.now();
        // Without the cable, whatever the captions heard meanwhile was our own voice.
        if (!cableOn) await Future<void>.delayed(const Duration(milliseconds: 600));
        _ears?.rebase();
        if (endAfter && _automation) break;
      }
    } finally {
      if (turn == _turn) _busy = false;
      _lastActivity = DateTime.now();
      if (active && turn == _turn && !(endAfter && _automation)) {
        _set(_usingMic ? 'Listening through the microphone…' : 'Listening through the live captions…');
      }
    }
    if (endAfter && _automation && active && turn == _turn) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _hangUp();
      await stop(reason: 'I ended the call: the goal was done.');
    }
  }

  Future<void> _say(String text) async {
    _lastSpoken = text;
    _set('Speaking…');
    await _voice.speakAndWait(text, rate: _callRate, onCall: true);
    if (!cableOn) await Future<void>.delayed(const Duration(milliseconds: 600));
    _ears?.rebase();
    _lastActivity = DateTime.now();
    _set(_usingMic ? 'Listening through the microphone…' : 'Listening through the live captions…');
  }

  /// Presses the call app's end-call button (accessibility), else the hang-up key.
  Future<void> _hangUp() async {
    final screen = ScreenAutomationService();
    for (final label in const ['End call', 'Leave call', 'Hang up', 'End']) {
      if (await screen.clickByText(label)) return;
    }
    try {
      final sh = ShizukuService();
      if (await sh.checkAvailability() && sh.hasPermission) await sh.runCommand('input keyevent 6');
    } catch (_) {}
  }

  Future<void> stop({String reason = ''}) async {
    if (!active && !_prepared) return;
    final wasActive = active;
    active = false;
    _prepared = false;
    _callWatch?.cancel();
    _callWatch = null;
    _turnWatch?.cancel();
    _turnWatch = null;
    _ears?.stop();
    _ears = null;
    VoiceService.talkLock = false;
    unawaited(_voice.stopSpeaking());
    unawaited(_voice.stopListening());
    CallBackground.onHangup(null);
    unawaited(CallBackground.stop());
    await CableService.instance.stop();
    await _restoreCaptions();
    if (identical(current, this)) current = null;
    status = reason.isEmpty ? 'Stopped.' : reason;
    notifyListeners();
    if (wasActive && lines.isNotEmpty) unawaited(_report(reason));
  }

  /// After the call: a short summary, as a notification and on the Talk screen.
  Future<void> _report(String reason) async {
    final transcript = lines.map((l) => '${l.me ? 'Me' : (who.isEmpty ? 'Them' : who)}: ${l.text}').join('\n');
    var summary = '';
    try {
      final r = await LlmClient(aiService).complete(
        [
          {
            'role': 'system',
            'content': 'Summarise this phone call for the person who asked for it, in 3-5 short plain lines: '
                'was the goal achieved, what was agreed or learned (dates, amounts, names), and anything left for them to do.',
          },
          {'role': 'user', 'content': 'Goal: ${brief.trim()}\n\nTranscript:\n$transcript'},
        ],
        temperature: 0.2,
        maxTokens: 300,
      );
      summary = r.content.trim();
    } catch (_) {}
    if (summary.isEmpty) summary = transcript.length > 600 ? transcript.substring(transcript.length - 600) : transcript;
    final label = who.isEmpty ? 'the call' : 'the call with $who';
    lastReport = 'Report on $label${reason.isEmpty ? '' : ' ($reason)'}\n\n$summary';
    notifyListeners();
    reportStream.add(lastReport);
    try {
      await NotificationService().showTaskCompleteNotification('Call report: ${who.isEmpty ? 'call finished' : who}', summary.length > 300 ? '${summary.substring(0, 300)}…' : summary);
    } catch (_) {}
  }
}
