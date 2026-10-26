import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../agent/llm_client.dart';
import '../agent/prefs.dart';
import '../services/ai_service.dart';
import '../services/call_background.dart';
import '../services/call_ears.dart';
import '../services/neural_tts.dart';
import '../services/voice_service.dart';

/// "Talk on my call": while a WhatsApp/Telegram call is running, the agent
/// speaks AS the user, following a short brief, and answers what the other
/// person says. It hears them through the phone's own live captions (falling
/// back to the microphone) and speaks through the speaker, so the call's
/// microphone picks it up — Android offers no direct audio link between apps.
class CallTalkScreen extends StatefulWidget {
  final AiService aiService;
  const CallTalkScreen({super.key, required this.aiService});

  @override
  State<CallTalkScreen> createState() => _CallTalkScreenState();
}

class _Line {
  final bool me;
  final String text;
  _Line(this.me, this.text);
}

class _CallTalkScreenState extends State<CallTalkScreen> {
  final TextEditingController _brief = TextEditingController();
  final TextEditingController _opening = TextEditingController();
  final VoiceService _voice = VoiceService();
  late final LlmClient _llm = LlmClient(widget.aiService);
  final List<_Line> _lines = [];
  final List<String> _pending = [];
  CaptionEars? _ears;
  bool _active = false;
  bool _busy = false;
  bool _usingMic = false;
  String _status = '';
  String _lastSpoken = '';
  DateTime _startedAt = DateTime.now();

  @override
  void dispose() {
    _stop();
    _brief.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_active) return;
    if (_brief.text.trim().isEmpty) {
      setState(() => _status = 'Tell me what to say or get done on the call first.');
      return;
    }
    if (!(await Permission.microphone.request()).isGranted) {
      setState(() => _status = 'The microphone permission is needed (it is only used if captions are unavailable).');
      return;
    }
    await AgentPrefs.instance.load();
    await _voice.init();
    NeuralTts.instance.callMode = true; // don't steal audio focus from the call
    _lines.clear();
    _pending.clear();
    _lastSpoken = '';
    _startedAt = DateTime.now();
    setState(() {
      _active = true;
      _usingMic = false;
      _status = 'Listening through the phone\'s live captions…';
    });
    CallBackground.onHangup(_stop);
    await CallBackground.start('Talking on your call — tap Hang up to stop', phase: 'listening');

    _ears = CaptionEars(onHeard: _onHeard)..start();
    await CallBackground.minimize(); // back to the call
    final opening = _opening.text.trim();
    if (opening.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_active) await _say(opening);
    }
    unawaited(_watchEars());
  }

  /// If no caption window shows up, fall back to hearing through the mic.
  Future<void> _watchEars() async {
    await Future<void>.delayed(const Duration(seconds: 10));
    if (!_active || (_ears?.found ?? false)) return;
    _ears?.stop();
    _usingMic = true;
    if (mounted) setState(() => _status = 'No live captions found — listening through the microphone instead.');
    while (_active) {
      if (_busy) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final heard = await _voice.listenOnce(
        maxSpeech: const Duration(seconds: 20),
        endSilence: const Duration(milliseconds: 1300),
        noSpeechTimeout: const Duration(seconds: 60),
      );
      if (!_active) break;
      if (heard != null && heard.trim().isNotEmpty) _onHeard(heard.trim());
    }
  }

  void _onHeard(String text) {
    if (!_active) return;
    // The captions can pick up our own voice; ignore text that matches it.
    if (_similar(text, _lastSpoken)) return;
    _pending.add(text);
    if (mounted) setState(() => _lines.add(_Line(false, text)));
    unawaited(_respond());
  }

  static bool _similar(String a, String b) {
    if (b.isEmpty) return false;
    final wa = a.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 2).toSet();
    final wb = b.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 2).toSet();
    if (wa.isEmpty || wb.isEmpty) return false;
    return wa.intersection(wb).length / wa.length >= 0.7;
  }

  String get _persona {
    final name = AgentPrefs.instance.userName.trim().isEmpty ? 'the user' : AgentPrefs.instance.userName.trim();
    return '''You are on a live voice call and you speak AS $name, in the first person, on their behalf.

What $name wants from this call:
"${_brief.text.trim()}"

Rules:
- Sound like a natural person on the phone: one or two short spoken sentences, no lists, no markdown, no emojis.
- Reply in the language the other person is using (Hindi in Devanagari for Hindi, otherwise English).
- The other person's words come from automatic subtitles. They can contain mistakes and may include an English translation of what was said — answer what they meant.
- Stay within what $name asked for. Never invent facts, agree to payments, or give out passwords, OTPs, card or bank details; if asked for something outside the brief, say you will check and get back to them.
- If the other person sincerely asks whether you are an AI or a real person, say honestly that you are an AI assistant speaking on $name's behalf.
- When the conversation is clearly finished, say a short goodbye.
- If what you were given is only noise or filler and needs no reply, answer with exactly <silent>.''';
  }

  Future<void> _respond() async {
    if (_busy || !_active) return;
    _busy = true;
    if (_usingMic) await _voice.stopListening(); // never listen to ourselves
    try {
      while (_pending.isNotEmpty && _active) {
        _pending.clear();
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': _persona},
          for (final l in _lines.length > 14 ? _lines.sublist(_lines.length - 14) : _lines)
            {'role': l.me ? 'assistant' : 'user', 'content': l.text},
        ];
        if (mounted) setState(() => _status = 'Thinking…');
        String reply;
        try {
          final r = await _llm.complete(messages, temperature: 0.5, maxTokens: 220);
          reply = r.content.trim();
        } catch (e) {
          if (mounted) setState(() => _status = 'The model failed: $e');
          break;
        }
        if (reply.isEmpty || reply.contains('<silent>')) {
          _ears?.rebase();
          continue;
        }
        if (mounted) setState(() => _lines.add(_Line(true, reply)));
        await _say(reply);
      }
    } finally {
      _busy = false;
      if (_active && mounted) setState(() => _status = _usingMic ? 'Listening through the microphone…' : 'Listening through the live captions…');
    }
  }

  Future<void> _say(String text) async {
    _lastSpoken = text;
    if (mounted) setState(() => _status = 'Speaking…');
    await CallBackground.update('Speaking on your call…', phase: 'speaking');
    await _voice.speakAndWait(text);
    // Whatever the captions picked up while we talked is our own voice.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _ears?.rebase();
    await CallBackground.update('Listening…', phase: 'listening');
  }

  void _stop() {
    if (!_active && _ears == null) return;
    _active = false;
    _ears?.stop();
    _ears = null;
    NeuralTts.instance.callMode = false;
    unawaited(_voice.stopSpeaking());
    unawaited(_voice.stopListening());
    CallBackground.onHangup(null);
    unawaited(CallBackground.stop());
    if (mounted) setState(() => _status = 'Stopped.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Talk on my call')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'During a WhatsApp or Telegram call the agent speaks as you, following the brief below, and answers what the other person says. '
            'Turn on your phone\'s live captions (Xiaomi AI Subtitles or Live Caption) and put the call on speaker with the volume up.',
            style: TextStyle(height: 1.4, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _brief,
            enabled: !_active,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'What should I say or get done?',
              hintText: 'e.g. Ask Ravi whether the delivery reaches Friday, and tell him I will pay on delivery.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _opening,
            enabled: !_active,
            decoration: const InputDecoration(
              labelText: 'Opening line (optional)',
              hintText: 'Said first, a moment after you start',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          if (!_active)
            FilledButton.icon(onPressed: _start, icon: const Icon(Icons.call_rounded), label: const Text('Start — then go to the call'))
          else
            FilledButton.tonalIcon(onPressed: _stop, icon: const Icon(Icons.stop_circle_rounded), label: const Text('Stop')),
          if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_status)),
          const SizedBox(height: 10),
          const Text(
            'The agent will say it is an AI if the other person sincerely asks. Make sure the people you call are fine with it.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.35),
          ),
          const SizedBox(height: 12),
          for (final l in _lines)
            Align(
              alignment: l.me ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxWidth: 300),
                decoration: BoxDecoration(
                  color: l.me ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(l.text),
              ),
            ),
        ],
      ),
    );
  }
}
