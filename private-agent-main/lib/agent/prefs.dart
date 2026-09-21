import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_mode.dart';

/// User-tunable behaviour of the agent (non-secret).
class AgentPrefs extends ChangeNotifier {
  AgentPrefs._();
  static final AgentPrefs instance = AgentPrefs._();

  bool _loaded = false;

  /// Free-form instructions injected into every prompt ("Answer briefly", ...).
  String customInstructions = '';

  /// How the agent should address the user.
  String userName = '';

  AgentMode defaultMode = AgentMode.auto;

  /// Learn durable facts from conversations and store them in memory.md.
  bool autoLearnMemory = true;

  /// Read plain replies aloud.
  bool speakReplies = true;

  /// In Auto mode, ask before sending, calling, paying, deleting, posting...
  bool confirmSensitive = true;

  /// Ask the model to check the screen after each UI step (an extra model
  /// call per step, so off by default; failures are still detected).
  bool verifySteps = false;

  /// Let the agent type saved account credentials into apps (the model never
  /// sees the secrets, it only refers to an account by label).
  bool allowCredentialFill = true;

  /// Extra attempts for a failing step before re-planning.
  int maxRetries = 1;

  /// How many times the plan may be rewritten after failures.
  int maxReplans = 2;

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    customInstructions = p.getString('agent_custom_instructions') ?? '';
    userName = p.getString('agent_user_name') ?? '';
    defaultMode = AgentModeInfo.fromId(p.getString('agent_default_mode'));
    autoLearnMemory = p.getBool('agent_auto_learn') ?? true;
    speakReplies = p.getBool('agent_speak_replies') ?? true;
    confirmSensitive = p.getBool('agent_confirm_sensitive') ?? true;
    verifySteps = p.getBool('agent_verify_steps') ?? false;
    allowCredentialFill = p.getBool('agent_allow_credentials') ?? true;
    maxRetries = p.getInt('agent_max_retries') ?? 1;
    maxReplans = p.getInt('agent_max_replans') ?? 2;
    _loaded = true;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('agent_custom_instructions', customInstructions);
    await p.setString('agent_user_name', userName);
    await p.setString('agent_default_mode', defaultMode.id);
    await p.setBool('agent_auto_learn', autoLearnMemory);
    await p.setBool('agent_speak_replies', speakReplies);
    await p.setBool('agent_confirm_sensitive', confirmSensitive);
    await p.setBool('agent_verify_steps', verifySteps);
    await p.setBool('agent_allow_credentials', allowCredentialFill);
    await p.setInt('agent_max_retries', maxRetries);
    await p.setInt('agent_max_replans', maxReplans);
    notifyListeners();
  }
}
