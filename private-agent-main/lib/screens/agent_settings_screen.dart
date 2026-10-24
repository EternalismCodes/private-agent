import 'dart:async';
import 'package:flutter/material.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/tts_voices.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../agent/agent_mode.dart';
import '../agent/prefs.dart';
import '../widgets/screen_helpers.dart';

/// Preferences that shape how the agent behaves (API settings stay in the
/// original Settings screen).
class AgentSettingsScreen extends StatefulWidget {
  const AgentSettingsScreen({super.key});

  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends State<AgentSettingsScreen> {
  final AgentPrefs _prefs = AgentPrefs.instance;
  late final TextEditingController _name;
  late final TextEditingController _instructions;
  bool _ready = false;
  bool _overlayGranted = false;
  final FlutterTts _previewTts = FlutterTts();
  List<TtsVoice> _enVoices = [];
  List<TtsVoice> _hiVoices = [];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _instructions = TextEditingController();
    _prefs.load().then((_) {
      if (!mounted) return;
      setState(() {
        _name.text = _prefs.userName;
        _instructions.text = _prefs.customInstructions;
        _ready = true;
      });
    });
    _refreshOverlayStatus();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    final en = await TtsVoiceCatalog.list(_previewTts, 'en');
    final hi = await TtsVoiceCatalog.list(_previewTts, 'hi');
    if (!mounted) return;
    setState(() {
      _enVoices = en;
      _hiVoices = hi;
    });
  }

  Future<void> _preview(String lang) async {
    final chosen = lang == 'hi' ? _prefs.ttsHindiVoice : _prefs.ttsEnglishVoice;
    final list = lang == 'hi' ? _hiVoices : _enVoices;
    try {
      await _previewTts.stop();
      TtsVoice? pick;
      for (final v in list) {
        if (v.name == chosen) pick = v;
      }
      pick ??= list.isNotEmpty ? list.first : null;
      if (pick != null) {
        await _previewTts.setVoice({'name': pick.name, 'locale': pick.locale});
      } else {
        await _previewTts.setLanguage(lang == 'hi' ? 'hi-IN' : 'en-US');
      }
      await _previewTts.speak(lang == 'hi' ? 'नमस्ते, मैं आपकी मदद के लिए यहाँ हूँ।' : 'Hi, I am here to help you.');
    } catch (_) {}
  }

  Future<void> _openSystemVoiceSettings() async {
    try {
      await const AndroidIntent(action: 'com.android.settings.TTS_SETTINGS').launch();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open Settings → System → Languages → Text-to-speech output.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _previewTts.stop();
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _refreshOverlayStatus() async {
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) setState(() => _overlayGranted = granted);
  }

  Future<void> _save() async {
    _prefs.userName = _name.text.trim();
    _prefs.customInstructions = _instructions.text.trim();
    await _prefs.save();
  }

  Widget _switch(String title, String subtitle, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5, height: 1.35)),
      value: value,
      onChanged: (v) async {
        setState(() => onChanged(v));
        await _save();
      },
    );
  }

  List<Widget> _buildVoiceEngineSection() {
    Widget picker(String lang, String title, List<TtsVoice> voices, String current, void Function(String) set) {
      final names = voices.map((v) => v.name).toSet();
      final value = names.contains(current) ? current : '';
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('$lang-${voices.length}-$value'),
                isExpanded: true,
                initialValue: value,
                decoration: InputDecoration(labelText: title, border: const OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Automatic (best installed)')),
                  for (final v in voices) DropdownMenuItem(value: v.name, child: Text(v.label, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) async {
                  setState(() => set(v ?? ''));
                  await _save();
                },
              ),
            ),
            IconButton(
              tooltip: 'Preview',
              icon: const Icon(Icons.play_circle_outline_rounded),
              onPressed: () => _preview(lang),
            ),
          ],
        ),
      );
    }

    return [
      picker('en', 'English voice', _enVoices, _prefs.ttsEnglishVoice, (v) => _prefs.ttsEnglishVoice = v),
      picker('hi', 'Hindi voice', _hiVoices, _prefs.ttsHindiVoice, (v) => _prefs.ttsHindiVoice = v),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          _hiVoices.isEmpty
              ? 'No Hindi voice is installed yet. Install one (and a high-quality English voice) from your phone\'s text-to-speech settings — replies in Hindi then switch to it automatically.'
              : 'Replies are spoken in the Hindi voice when the text is Hindi, otherwise in the English voice. Uses the phone\'s own speech engine — nothing extra to run.',
          style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.35),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openSystemVoiceSettings,
            icon: const Icon(Icons.record_voice_over_rounded, size: 18),
            label: const Text('Get more natural voices'),
          ),
        ),
      ),
      const SizedBox(height: 4),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Agent preferences')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Agent preferences')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SectionLabel('About you'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _name,
              onChanged: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'What should I call you?',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _instructions,
              onChanged: (_) => _save(),
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Custom instructions',
                hintText: 'Keep answers short. Reply in Spanish. Never open Instagram.',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SectionLabel('Default mode'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in AgentMode.values)
                  ChoiceChip(
                    avatar: Icon(mode.icon, size: 16),
                    label: Text(mode.label),
                    selected: _prefs.defaultMode == mode,
                    onSelected: (_) async {
                      setState(() => _prefs.defaultMode = mode);
                      await _save();
                    },
                  ),
              ],
            ),
          ),
          const SectionLabel('Memory'),
          _switch(
            'Learn from conversations',
            'Save durable facts about you (preferences, routines, people) to memory.md automatically.',
            _prefs.autoLearnMemory,
            (v) => _prefs.autoLearnMemory = v,
          ),
          const SectionLabel('Voice'),
          _switch(
            'Read replies aloud',
            'Speak answers in Chat, Think and Auto mode.',
            _prefs.speakReplies,
            (v) => _prefs.speakReplies = v,
          ),
          ..._buildVoiceEngineSection(),
          const SectionLabel('Calls'),
          _switch(
            'Status bubble during calls',
            'A small floating pill shows what the agent is doing — listening, thinking, controlling your phone — while other apps are open.',
            _prefs.showCallOverlay,
            (v) => _prefs.showCallOverlay = v,
          ),
          ListTile(
            title: const Text(
              'Display over other apps',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
            ),
            subtitle: Text(
              _overlayGranted
                  ? 'Granted — the status bubble can show over other apps.'
                  : 'Needed for the status bubble, and lets scheduled and remote (Telegram) tasks bring the app forward.',
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
            trailing: _overlayGranted
                ? const Icon(Icons.check_circle_rounded, color: Colors.green)
                : TextButton(
                    onPressed: () async {
                      final granted = await FlutterOverlayWindow.requestPermission();
                      if (mounted) setState(() => _overlayGranted = granted ?? false);
                    },
                    child: const Text('Grant'),
                  ),
          ),
          const SizedBox(height: 8),
          const SectionLabel('Safety'),
          _switch(
            'Ask before sensitive steps',
            'In Auto mode, confirm before sending, calling, paying, deleting or posting as part of a plan.',
            _prefs.confirmSensitive,
            (v) => _prefs.confirmSensitive = v,
          ),
          _switch(
            'Allow filling saved logins',
            'Let the agent type saved account usernames and passwords into apps. The model never sees them.',
            _prefs.allowCredentialFill,
            (v) => _prefs.allowCredentialFill = v,
          ),
          const SectionLabel('Reliability'),
          _switch(
            'Double-check each step (slower)',
            'After every on-screen step, ask the model to compare the screen with what was expected. Adds one model call per step. Off by default: failed steps are detected and recovered anyway.',
            _prefs.verifySteps,
            (v) => _prefs.verifySteps = v,
          ),
          ListTile(
            title: const Text('Retries per step', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
            subtitle: Slider(
              value: _prefs.maxRetries.toDouble(),
              min: 0,
              max: 3,
              divisions: 3,
              label: '${_prefs.maxRetries}',
              onChanged: (v) => setState(() => _prefs.maxRetries = v.round()),
              onChangeEnd: (_) => _save(),
            ),
            trailing: Text('${_prefs.maxRetries}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          ListTile(
            title: const Text('Re-plans after failures', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
            subtitle: Slider(
              value: _prefs.maxReplans.toDouble(),
              min: 0,
              max: 4,
              divisions: 4,
              label: '${_prefs.maxReplans}',
              onChanged: (v) => setState(() => _prefs.maxReplans = v.round()),
              onChangeEnd: (_) => _save(),
            ),
            trailing: Text('${_prefs.maxReplans}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
