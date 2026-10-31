import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/ai_service.dart';
import '../services/call_talk_session.dart';

/// "Talk on my call": while a WhatsApp/Telegram call is running, the agent
/// speaks AS the user, following a short brief, and answers what the other
/// person says. Speech goes through the virtual cable straight into the call
/// (loudspeaker if the cable can't start); hearing uses the phone's live
/// captions. The same session starts automatically when you ask the agent to
/// "call X and talk to them" — this screen shows it, or starts one by hand.
class CallTalkScreen extends StatefulWidget {
  final AiService aiService;
  const CallTalkScreen({super.key, required this.aiService});

  @override
  State<CallTalkScreen> createState() => _CallTalkScreenState();
}

class _CallTalkScreenState extends State<CallTalkScreen> {
  final TextEditingController _brief = TextEditingController();
  final TextEditingController _opening = TextEditingController();
  CallTalkSession? _session;
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _session = CallTalkSession.current; // pick up a session the agent started
    _session?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session?.removeListener(_changed);
    _brief.dispose();
    _opening.dispose();
    super.dispose(); // a running session keeps going; Stop / Hang up ends it
  }

  bool get _active => _session?.active ?? false;

  Future<void> _start() async {
    if (_active) return;
    if (_brief.text.trim().isEmpty) {
      setState(() => _hint = 'Tell me what to say or get done on the call first.');
      return;
    }
    if (!(await Permission.microphone.request()).isGranted) {
      setState(() => _hint = 'The microphone permission is needed (it is only used if captions are unavailable).');
      return;
    }
    _session?.removeListener(_changed);
    final s = CallTalkSession(
      aiService: widget.aiService,
      brief: _brief.text,
      opening: _opening.text,
      openingWait: const Duration(seconds: 3),
    );
    s.addListener(_changed);
    setState(() {
      _hint = '';
      _session = s;
    });
    await s.start();
  }

  @override
  Widget build(BuildContext context) {
    final status = _hint.isNotEmpty ? _hint : (_session?.status ?? '');
    return Scaffold(
      appBar: AppBar(title: const Text('Talk on my call')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'During a WhatsApp or Telegram call the agent speaks as you, following the brief below, and answers what the other person says. '
            'Turn on your phone\'s live captions (Xiaomi AI Subtitles or Live Caption) and Shizuku: my voice then goes straight into the call '
            'through the virtual cable, no loudspeaker needed. Without Shizuku, put the call on speaker with the volume up.\n\n'
            'You can also just tell the agent: "call Ravi on WhatsApp and ask him about Friday" — it places the call and starts this by itself.',
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
            FilledButton.tonalIcon(onPressed: () => _session?.stop(reason: 'Stopped by you.'), icon: const Icon(Icons.stop_circle_rounded), label: const Text('Stop')),
          if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(status)),
          const SizedBox(height: 10),
          const Text(
            'The agent will say it is an AI if the other person sincerely asks. Make sure the people you call are fine with it.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.35),
          ),
          if (CallTalkSession.lastReport.isNotEmpty && !_active)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(CallTalkSession.lastReport, style: const TextStyle(height: 1.4)))),
          const SizedBox(height: 12),
          for (final l in _session?.lines ?? const <TalkLine>[])
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
