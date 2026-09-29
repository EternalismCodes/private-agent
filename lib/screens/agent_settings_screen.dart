import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const MethodChannel _localTts = MethodChannel('com.privateagent/localtts');
  final AgentPrefs _prefs = AgentPrefs.instance;
  late final TextEditingController _name;
  late final TextEditingController _instructions;
  bool _ready = false;
  bool _overlayGranted = false;
  bool _hindiReady = false;
  bool _naturalReady = false;
  bool _naturalDownloading = false;
  int _naturalProgress = -1;
  Timer? _progressTimer;

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
    _refreshVoiceStatus();
  }

  Future<void> _refreshVoiceStatus() async {
    try {
      final hindi = await _localTts.invokeMethod<bool>('isHindiReady');
      final natural = await _localTts.invokeMethod<bool>('isNaturalReady');
      if (!mounted) return;
      setState(() {
        _hindiReady = hindi == true;
        _naturalReady = natural == true;
      });
    } catch (_) {
      // Local TTS not available on this platform build — the System voice
      // option still works fine.
    }
  }

  Future<void> _downloadNaturalVoice() async {
    if (_naturalDownloading) return;
    setState(() {
      _naturalDownloading = true;
      _naturalProgress = -1;
    });
    _progressTimer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      try {
        final pct = await _localTts.invokeMethod<int>('naturalDownloadProgress');
        if (mounted && pct != null) setState(() => _naturalProgress = pct);
      } catch (_) {}
    });
    bool ok = false;
    try {
      ok = await _localTts.invokeMethod<bool>('downloadNatural') == true;
    } catch (_) {
      ok = false;
    }
    _progressTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _naturalDownloading = false;
      _naturalReady = ok;
      _naturalProgress = -1;
    });
    if (ok) {
      // Now that the better voice is available, use it by default — for
      // English as well as Hindi, not just as a Hindi-only fallback.
      _prefs.ttsEngine = 'natural';
      await _save();
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Natural voice downloaded and set as the active voice.')),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not download the natural voice — check your connection and try again.')),
      );
    }
  }

  Future<void> _deleteNaturalVoice() async {
    try {
      await _localTts.invokeMethod('deleteNatural');
    } catch (_) {}
    if (_prefs.ttsEngine == 'natural') {
      _prefs.ttsEngine = 'system';
      await _save();
    }
    if (mounted) setState(() => _naturalReady = false);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
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
    Widget chip(String id, String label, {bool enabled = true}) => ChoiceChip(
          label: Text(label),
          selected: _prefs.ttsEngine == id,
          onSelected: !enabled
              ? null
              : (_) async {
                  setState(() => _prefs.ttsEngine = id);
                  await _save();
                },
        );

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            chip('system', 'System voice'),
            chip('hindi', 'Hindi (built-in)'),
            chip('natural', _naturalReady ? 'Natural voice' : 'Natural voice (download)'),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          switch (_prefs.ttsEngine) {
            'hindi' => 'A small Hindi neural voice bundled in the app — nothing to download, works fully offline, used for both replies and calls.',
            'natural' => 'A bigger, more natural-sounding local voice for both English and Hindi. Runs fully on-device once downloaded — no server involved.',
            _ => 'The phone\'s own installed text-to-speech.',
          },
          style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.35),
        ),
      ),
      if (!_naturalReady)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: _naturalDownloading
              ? Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(_naturalProgress >= 0 ? 'Downloading… $_naturalProgress%' : 'Downloading…', style: const TextStyle(fontSize: 12.5)),
                  ],
                )
              : OutlinedButton.icon(
                  onPressed: _downloadNaturalVoice,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download natural voice (~130MB, one-time)'),
                ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _deleteNaturalVoice,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Remove downloaded natural voice'),
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
