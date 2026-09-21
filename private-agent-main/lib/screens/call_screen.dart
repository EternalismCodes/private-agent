import 'dart:async';
import 'package:flutter/material.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_mode.dart';
import '../agent/json_utils.dart';
import '../agent/plan.dart';
import '../agent/prefs.dart';
import '../models/chat_message.dart';
import '../services/voice_service.dart';

enum CallPhase { connecting, listening, thinking, acting, speaking, ended }

/// Hands-free voice conversation with the agent: you speak, the agent answers
/// out loud and (in Auto mode) does the task on the phone, then listens again.
/// Pops with the transcript so the chat screen can keep it.
class CallScreen extends StatefulWidget {
  final AgentController controller;
  final VoiceService voice;

  /// Brings PrivateAgent back to the foreground after the agent operated
  /// another app, so the microphone can be used again.
  final Future<void> Function() bringToFront;

  const CallScreen({
    super.key,
    required this.controller,
    required this.voice,
    required this.bringToFront,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  CallPhase _phase = CallPhase.connecting;
  String _heard = '';
  String _said = '';
  String _progress = '';
  bool _active = true;
  final List<ChatMessage> _transcript = [];
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _tick;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

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
      if (!mounted) return;
      setState(() {
        _phase = CallPhase.acting;
        _progress = msg;
      });
    },
  );

  static final RegExp _hangup = RegExp(
    r"\b(hang up|goodbye|good bye|bye|end call|end the call|that's all|thats all|stop listening)\b",
    caseSensitive: false,
  );
  static final RegExp _yes = RegExp(
    r"\b(yes|yeah|yep|sure|go ahead|ok|okay|do it|proceed|confirm|please do)\b",
    caseSensitive: false,
  );
  static final RegExp _no = RegExp(r"\b(no|nope|don't|dont|stop|cancel|never)\b", caseSensitive: false);

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
    widget.voice.stopListening();
    widget.voice.stopSpeaking();
    super.dispose();
  }

  Future<void> _say(String text) async {
    if (!_active || text.trim().isEmpty) return;
    if (mounted) {
      setState(() {
        _phase = CallPhase.speaking;
        _said = text;
      });
    }
    await widget.voice.speakAndWait(JsonUtils.forSpeech(text, maxChars: 420));
  }

  Future<bool> _confirmByVoice(PlanStep step) async {
    await widget.bringToFront();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await _say('I am about to ${step.title}. Should I go ahead? Say yes or no.');
    for (var attempt = 0; attempt < 2 && _active; attempt++) {
      if (mounted) setState(() => _phase = CallPhase.listening);
      final answer = await widget.voice.listenOnce(
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(seconds: 2),
      );
      if (answer == null || answer.trim().isEmpty) continue;
      if (_no.hasMatch(answer)) return false;
      return _yes.hasMatch(answer);
    }
    return false;
  }

  Future<void> _loop() async {
    try {
      await widget.voice.init();
      final name = AgentPrefs.instance.userName;
      await _say(name.isEmpty ? 'Hi, I am listening. What can I do for you?' : 'Hi $name, I am listening. What can I do for you?');

      var silence = 0;
      while (_active) {
        if (mounted) setState(() => _phase = CallPhase.listening);
        final heard = await widget.voice.listenOnce();
        if (!_active) break;

        if (heard == null || heard.trim().isEmpty) {
          silence++;
          if (silence >= 3) {
            await _say('I did not hear anything, so I will end the call. Talk to you soon.');
            break;
          }
          continue;
        }
        silence = 0;
        final text = heard.trim();
        if (_hangup.hasMatch(text)) {
          await _say('Okay, talk to you later.');
          break;
        }

        _transcript.add(ChatMessage(role: 'user', content: text));
        if (mounted) {
          setState(() {
            _heard = text;
            _phase = CallPhase.thinking;
            _progress = '';
          });
        }

        final result = await widget.controller.handle(text, AgentMode.auto, _ui);
        if (!_active) break;

        if (result.usedDevice) {
          await widget.bringToFront();
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
        await _say(result.reply.isEmpty ? 'Done.' : result.reply);
      }
    } catch (e) {
      await _say('Sorry, something went wrong: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      _finish();
    }
  }

  void _finish() {
    if (!mounted || _phase == CallPhase.ended) return;
    _active = false;
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
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _hangUp();
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
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: _hangUp,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFEF4444)),
                    child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 32),
                  ),
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
