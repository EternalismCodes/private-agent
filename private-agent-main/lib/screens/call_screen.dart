import 'dart:async';
import 'package:flutter/material.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_mode.dart';
import '../agent/json_utils.dart';
import '../agent/plan.dart';
import '../agent/prefs.dart';
import '../models/chat_message.dart';
import '../services/call_background.dart';
import '../services/voice_service.dart';

enum CallPhase { connecting, listening, thinking, acting, speaking, ended }

/// Hands-free voice call. You speak, the agent answers out loud and does the
/// task on the phone. The call keeps running while other apps are open (a
/// foreground service keeps the microphone alive), so "open Instagram" simply
/// opens Instagram and the agent keeps listening. It ends when you say bye,
/// tap Hang up (here or in the notification), or after a long silence.
///
/// Pops with the transcript so the chat screen can keep it.
class CallScreen extends StatefulWidget {
  final AgentController controller;
  final VoiceService voice;

  const CallScreen({
    super.key,
    required this.controller,
    required this.voice,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  CallPhase _phase = CallPhase.connecting;
  String _heard = '';
  String _said = '';
  String _progress = '';
  String _lastNotification = '';
  bool _active = true;
  bool _confirming = false;
  bool _finished = false;
  final List<String> _speechQueue = [];
  Future<void>? _speaking;
  DateTime _lastActivity = DateTime.now();
  final List<ChatMessage> _transcript = [];
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _tick;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  static const Duration _idleLimit = Duration(minutes: 5);

  late final AgentUi _ui = AgentUi(
    addMessage: (m) {
      _transcript.add(m);
      return m;
    },
    refresh: () {
      if (mounted) setState(() {});
    },
    removeMessage: (m) => _transcript.remove(m),
    confirmStep: _confirmByVoice,
    onProgress: (msg) {
      _lastActivity = DateTime.now();
      if (_speaking == null) _setPhase(CallPhase.acting, progress: msg);
    },
    speak: _enqueueSpeech,
  );

  static final RegExp _goodbye = RegExp(
    r"\b(bye|goodbye|good bye|hang up|end (the )?call|that's all|thats all|that is all|that's it|thats it|talk (to you )?later|see you|stop listening|we're done|we are done|i'm done|im done|disconnect)\b",
    caseSensitive: false,
  );
  static final RegExp _stopWords = RegExp(
    r"\b(stop|cancel|abort|halt|never ?mind|forget it)\b",
    caseSensitive: false,
  );
  static final RegExp _yes = RegExp(
    r"\b(yes|yeah|yep|sure|go ahead|ok|okay|do it|proceed|confirm|please do)\b",
    caseSensitive: false,
  );
  static final RegExp _no = RegExp(r"\b(no|nope|don't|dont|stop|cancel|never)\b", caseSensitive: false);

  /// Short utterances that contain a goodbye phrase end the call at once
  /// (longer ones are left to the model, which can also end the call).
  static bool _isGoodbye(String text) =>
      _goodbye.hasMatch(text) && text.trim().split(RegExp(r'\s+')).length <= 8;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loop());
  }

  @override
  void dispose() {
    _active = false;
    _tick?.cancel();
    _pulse.dispose();
    CallBackground.onHangup(null);
    widget.voice.stopListening();
    widget.voice.stopSpeaking();
    super.dispose();
  }

  void _setPhase(CallPhase phase, {String? progress}) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      if (progress != null) _progress = progress;
    });
    final text = switch (phase) {
      CallPhase.listening => 'Listening…',
      CallPhase.thinking => 'Thinking…',
      CallPhase.speaking => 'Speaking…',
      CallPhase.acting => _progress.isEmpty
          ? 'Working on your phone…'
          : (_progress.length > 70 ? '${_progress.substring(0, 70)}…' : _progress),
      _ => 'On a call',
    };
    if (text != _lastNotification) {
      _lastNotification = text;
      CallBackground.update(text);
    }
  }

  static const double _speechRate = 0.58;

  Future<void> _say(String text) async {
    if (!_active || text.trim().isEmpty) return;
    await _flushSpeech();
    if (mounted) setState(() => _said = text);
    _setPhase(CallPhase.speaking);
    await widget.voice.speakAndWait(JsonUtils.forSpeech(text, maxChars: 420), rate: _speechRate);
  }

  /// Sentences are spoken one after another as soon as they arrive, so the
  /// agent starts talking while the model is still writing the rest.
  void _enqueueSpeech(String sentence) {
    if (!_active || sentence.trim().isEmpty) return;
    _speechQueue.add(sentence);
    if (_speaking == null) {
      widget.voice.stopListening(); // never listen to our own voice
      _speaking = _drainSpeech();
    }
  }

  Future<void> _drainSpeech() async {
    while (_speechQueue.isNotEmpty && _active) {
      final sentence = _speechQueue.removeAt(0);
      _setPhase(CallPhase.speaking);
      if (mounted) setState(() => _said = sentence);
      await widget.voice.speakAndWait(JsonUtils.forSpeech(sentence, maxChars: 300), rate: _speechRate);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250)); // let the echo die down
    _speaking = null;
  }

  Future<void> _flushSpeech() async {
    while (_speaking != null && _active) {
      await _speaking;
    }
  }

  Future<bool> _confirmByVoice(PlanStep step) async {
    _confirming = true;
    try {
      await widget.voice.stopListening();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _say('I am about to ${step.title}. Should I go ahead? Say yes or no.');
      for (var attempt = 0; attempt < 2 && _active; attempt++) {
        _setPhase(CallPhase.listening);
        final answer = await widget.voice.listenOnce(
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 2),
        );
        if (answer == null || answer.trim().isEmpty) continue;
        if (_no.hasMatch(answer)) return false;
        return _yes.hasMatch(answer);
      }
      return false;
    } finally {
      _confirming = false;
    }
  }

  Future<void> _loop() async {
    try {
      await widget.voice.init();
      if (!widget.voice.isReady) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Speech recognition needs the microphone permission.'),
            ),
          );
        }
        return;
      }

      // Foreground service: keeps the microphone usable in the background.
      await CallBackground.start('Listening…');
      CallBackground.onHangup(_hangUp);

      final name = AgentPrefs.instance.userName;
      await _say(
        name.isEmpty
            ? 'Hi, I am on the line. What can I do for you?'
            : 'Hi $name, I am on the line. What can I do for you?',
      );

      String? pending;
      while (_active) {
        String? heard = pending;
        pending = null;
        if (heard == null) {
          _setPhase(CallPhase.listening);
          heard = await widget.voice.listenOnce(
            listenFor: const Duration(seconds: 20),
            pauseFor: const Duration(milliseconds: 1500),
          );
        }
        if (!_active) break;

        final text = (heard ?? '').trim();
        if (text.isEmpty) {
          if (DateTime.now().difference(_lastActivity) > _idleLimit) {
            await _say('I have not heard from you for a while, so I am ending the call.');
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        _lastActivity = DateTime.now();

        if (_isGoodbye(text)) {
          await _say('Goodbye!');
          break;
        }

        _transcript.add(ChatMessage(role: 'user', content: text));
        if (mounted) setState(() => _heard = text);
        _setPhase(CallPhase.thinking, progress: '');

        // Work on the request while still listening, so the user can say
        // "stop" (or give the next command) without touching the phone.
        final work = widget.controller.handle(text, AgentMode.auto, _ui, voice: true);
        var finished = false;
        unawaited(work.whenComplete(() {
          finished = true;
          widget.voice.stopListening();
        }));

        var hangUpAfter = false;
        while (!finished && _active) {
          if (_confirming || _speaking != null) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          final said = (await widget.voice.listenOnce(
                listenFor: const Duration(seconds: 12),
                pauseFor: const Duration(milliseconds: 1500),
              ) ??
              '')
              .trim();
          if (said.isEmpty || finished || _confirming || _speaking != null) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          _lastActivity = DateTime.now();
          if (_isGoodbye(said)) {
            hangUpAfter = true;
            widget.controller.cancel();
          } else if (_stopWords.hasMatch(said)) {
            widget.controller.cancel();
          } else {
            pending = said;
          }
        }

        final result = await work;
        if (!_active) break;

        if (hangUpAfter) {
          await _say('Okay, stopping. Goodbye!');
          break;
        }
        if (result.spoken) {
          await _flushSpeech();
        } else {
          await _say(result.reply.isEmpty ? 'Done.' : result.reply);
        }
        if (result.endCall) break;
      }
    } catch (e) {
      await _say('Sorry, something went wrong: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      await _finish();
    }
  }

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    _active = false;
    CallBackground.onHangup(null);
    await widget.voice.stopListening();
    await widget.voice.stopSpeaking();
    await CallBackground.stop();
    if (!mounted) return;
    setState(() => _phase = CallPhase.ended);
    Navigator.of(context).pop(_transcript);
  }

  void _hangUp() {
    _active = false;
    widget.controller.cancel();
    widget.voice.stopListening();
    widget.voice.stopSpeaking();
    _finish();
  }

  String get _label {
    switch (_phase) {
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.listening:
        return 'Listening';
      case CallPhase.thinking:
        return 'Thinking…';
      case CallPhase.acting:
        return 'Working on your phone';
      case CallPhase.speaking:
        return 'Speaking';
      case CallPhase.ended:
        return 'Call ended';
    }
  }

  Color get _color {
    switch (_phase) {
      case CallPhase.listening:
        return const Color(0xFF22C55E);
      case CallPhase.thinking:
        return const Color(0xFFF59E0B);
      case CallPhase.acting:
        return const Color(0xFF38BDF8);
      case CallPhase.speaking:
        return const Color(0xFF818CF8);
      default:
        return const Color(0xFF94A3B8);
    }
  }

  String get _duration {
    final s = _clock.elapsed.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back never ends the call: it just sends the app to the background,
      // the call keeps running (hang up with the button, by voice, or from
      // the notification).
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) CallBackground.minimize();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1E1B4B), Color(0xFF0B0F19)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 28),
                Text(
                  'PrivateAgent',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(_duration, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
                const Spacer(),
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final active = _phase == CallPhase.listening || _phase == CallPhase.speaking;
                    final scale = active ? 1 + _pulse.value * 0.12 : 1.0;
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _color.withValues(alpha: 0.16),
                          border: Border.all(color: _color, width: 2.5),
                          boxShadow: [
                            BoxShadow(color: _color.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 4),
                          ],
                        ),
                        child: Icon(
                          _phase == CallPhase.acting
                              ? Icons.touch_app_rounded
                              : (_phase == CallPhase.thinking ? Icons.psychology_rounded : Icons.graphic_eq_rounded),
                          size: 64,
                          color: _color,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 26),
                Text(
                  _label,
                  style: TextStyle(color: _color, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                if (_phase == CallPhase.acting && _progress.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                    child: Text(
                      _progress,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                    ),
                  ),
                const Spacer(),
                if (_heard.isNotEmpty) _caption('You', _heard),
                if (_said.isNotEmpty) _caption('Agent', _said),
                const SizedBox(height: 8),
                Text(
                  'Say "bye" to end the call. It keeps listening while other apps are open.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11.5),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: CallBackground.minimize,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        child: const Icon(Icons.minimize_rounded, color: Colors.white, size: 28),
                      ),
                    ),
                    const SizedBox(width: 36),
                    GestureDetector(
                      onTap: _hangUp,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFEF4444)),
                        child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 32),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _caption(String who, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            who.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14, height: 1.35),
          ),
        ],
      ),
    );
  }
}
