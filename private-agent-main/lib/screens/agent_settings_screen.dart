import 'package:flutter/material.dart';
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
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
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
