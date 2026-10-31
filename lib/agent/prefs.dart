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

  /// Shows a small status pill (listening/thinking/controlling your phone)
  /// over other apps while a call is active.
  bool showCallOverlay = true;

  /// Chosen text-to-speech voices ('' = automatically use the best voice
  /// installed on the phone). Replies are spoken in the Hindi voice when the
  /// text is Hindi, otherwise the English one.
  String ttsEnglishVoice = '';
  String ttsHindiVoice = '';

  /// Talk mode (agent speaking on a call) may use its own, faster model/key.
  /// Empty key = use the main provider.
  String talkApiKey = '';
  String talkBaseUrl = '';
  String talkModel = '';

  /// Full automation for calls: no confirmation before calling, short
  /// stalling fillers while thinking, the agent hangs up when the brief is
  /// done, and a report of the call is posted afterwards.
  bool talkAutomation = false;

  /// App assistant: skip BOTH confirmations (start of a risky task, checkout).
  bool assistAutonomous = false;

  Future<void> reload() async {
    _loaded = false;
    await load();
  }

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
    showCallOverlay = p.getBool('agent_show_call_overlay') ?? true;
    ttsEnglishVoice = p.getString('agent_tts_voice_en') ?? '';
    ttsHindiVoice = p.getString('agent_tts_voice_hi') ?? '';
    talkApiKey = p.getString('talk_api_key') ?? '';
    talkBaseUrl = p.getString('talk_base_url') ?? '';
    talkModel = p.getString('talk_model') ?? '';
    talkAutomation = p.getBool('talk_automation') ?? false;
    assistAutonomous = p.getBool('assist_autonomous') ?? false;
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
    await p.setBool('agent_show_call_overlay', showCallOverlay);
    await p.setString('agent_tts_voice_en', ttsEnglishVoice);
    await p.setString('agent_tts_voice_hi', ttsHindiVoice);
    await p.setString('talk_api_key', talkApiKey);
    await p.setString('talk_base_url', talkBaseUrl);
    await p.setString('talk_model', talkModel);
    await p.setBool('talk_automation', talkAutomation);
    await p.setBool('assist_autonomous', assistAutonomous);
    notifyListeners();
  }
}
