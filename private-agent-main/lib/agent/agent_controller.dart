import 'dart:async';
import 'dart:math' as math;
import 'package:intl/intl.dart';
import '../models/agent_action.dart';
import '../models/chat_message.dart';
import '../services/notification_service.dart';
import 'agent_context.dart';
import 'agent_mode.dart';
import 'json_utils.dart';
import 'memory_service.dart';
import 'plan.dart';
import '../services/skill_memory_service.dart';
import 'app_opener.dart';
import 'llm_client.dart';
import 'plan_cache.dart';
import 'plan_runner.dart';
import 'planner.dart';
import 'quick_link.dart';
import 'scheduler_service.dart';

/// Callbacks through which the controller talks to whatever screen hosts it
/// (the chat screen, or the voice call screen).
class AgentUi {
  /// Adds a message to the conversation and returns it (it may be mutated
  /// afterwards, followed by [refresh]).
  final ChatMessage Function(ChatMessage message) addMessage;
  final void Function() refresh;
  final void Function(ChatMessage message) removeMessage;

  /// Asks the user to approve a sensitive step.
  final Future<bool> Function(PlanStep step) confirmStep;

  /// Short progress lines while the phone is being operated.
  final void Function(String message) onProgress;

  /// Voice calls only: receives finished sentences while the reply is still
  /// streaming, so speech can start before the model has finished writing.
  final void Function(String text)? speak;

  const AgentUi({
    required this.addMessage,
    required this.refresh,
    required this.removeMessage,
    required this.confirmStep,
    required this.onProgress,
    this.speak,
  });
}

class AgentTurnResult {
  final String reply;
  final bool usedDevice;
  final bool success;

  /// Whether the reply is worth reading aloud.
  final bool speak;

  /// The user is done: the voice call should end after the reply is spoken.
  final bool endCall;

  /// The reply was already spoken sentence by sentence while it streamed.
  final bool spoken;

  const AgentTurnResult({
    required this.reply,
    this.usedDevice = false,
    this.success = true,
    this.speak = false,
    this.endCall = false,
    this.spoken = false,
  });
}

/// Routes a user message according to the selected [AgentMode]. The phone is
/// only ever operated through the existing accessibility engine (via
/// [PlanRunner] / [ActionHandler]).
class AgentController {
  final AgentContext ctx;
  AgentController(this.ctx);

  final List<Map<String, String>> _history = [];
  PlanRunner? _runner;
  bool _busy = false;
  bool _cancelled = false;
  bool _voiceCall = false;
  bool _unattended = false;
  bool _spokeThisTurn = false;
  int _runId = 0;
  Timer? _watchdog;

  bool get busy => _busy;

  void resetHistory() => _history.clear();

  void seedHistory(List<ChatMessage> messages) {
    _history.clear();
    for (final m in messages) {
      if (m.actionResult != null || m.plan != null) continue;
      if (m.content.trim().isEmpty) continue;
      _history.add({'role': m.role, 'content': m.content});
    }
    _trimHistory();
  }

  void _trimHistory() {
    if (_history.length > 20) {
      _history.removeRange(0, _history.length - 20);
    }
  }

  /// Stops whatever is running: aborts in-flight model requests immediately
  /// (so nothing can hang on a slow provider) and the phone-control loop.
  void cancel() {
    _cancelled = true;
    LlmClient.abortAll();
    _runner?.cancel();
    ctx.actions.cancelTask();
  }

  /// Last resort when a run does not wind down after [cancel].
  void forceReset() {
    cancel();
    _runId++;
    _busy = false;
    _watchdog?.cancel();
  }

  // ─── Entry points ──────────────────────────────────────────────────────

  Future<AgentTurnResult> handle(
    String rawText,
    AgentMode mode,
    AgentUi ui, {
    bool voice = false,
    bool unattended = false,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) return const AgentTurnResult(reply: '');
    if (_busy) {
      return const AgentTurnResult(reply: 'I am still working on the previous request.', success: false);
    }
    _busy = true;
    _cancelled = false;
    _voiceCall = voice;
    _unattended = unattended;
    _spokeThisTurn = false;
    final myRun = ++_runId;
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(minutes: 15), cancel);
    try {
      await ctx.ensureLoaded();

      // "open <app>" needs no model at all.
      if (mode == AgentMode.auto || mode == AgentMode.planExecute) {
        final local = await _tryLocalIntent(text, ui);
        if (local != null) return local;
        // "search X on youtube/facebook/instagram": build the link and open
        // it straight away, no model call and no screen-automation loop.
        final quickLink = await _tryQuickLink(text, ui);
        if (quickLink != null) return quickLink;
        // A user-authored skill whose name or trigger phrase was actually
        // said runs directly — this is what makes a skill you just created
        // usable everywhere (chat, Auto, calls) without depending on the
        // model choosing to call it.
        final skillHit = await _tryUserSkill(text, mode, ui);
        if (skillHit != null) return skillHit;
        final template = await _tryTemplate(text, mode, ui);
        if (template != null) return template;
      }

      // A request that already worked once is repeated without asking the
      // model what to do: the saved steps run straight away.
      if (mode == AgentMode.auto || mode == AgentMode.planExecute) {
        final cached = await PlanCache.instance.find(text);
        if (cached != null) {
          return await _runCached(cached, text, mode, ui);
        }
      }

      // "Remember that ..." is handled locally, in every mode.
      final explicit = MemoryService.explicitFact(text);
      if (explicit != null) {
        final saved = await ctx.memory.addFact('Facts & notes', explicit);
        if (saved == MemoryAddResult.sensitive) {
          const note =
              'That looks like a secret (password, PIN, card or ID number), so I did not put it in memory. Save it in **Accounts** instead, where it is encrypted.';
          ui.addMessage(ChatMessage(role: 'assistant', content: note, mode: mode.id));
          return const AgentTurnResult(reply: note, speak: true);
        }
      }

      switch (mode) {
        case AgentMode.chat:
          return await _converse(text, ui, think: false);
        case AgentMode.think:
          return await _converse(text, ui, think: true);
        case AgentMode.plan:
          return await _propose(text, mode, ui);
        case AgentMode.planExecute:
          // Plan & Execute never waits for approval: plan, then run.
          return await _planAndExecute(
            text,
            '',
            ui,
            mode: 'planExecute',
            askConfirmation: false,
            cacheKey: text,
          );
        case AgentMode.auto:
          return await _auto(text, ui);
      }
    } catch (e) {
      if (_cancelled) return const AgentTurnResult(reply: 'Stopped.', success: false);
      final message = 'Error: ${e.toString().replaceFirst('Exception: ', '')}';
      ui.addMessage(ChatMessage(role: 'assistant', content: message, mode: mode.id));
      return AgentTurnResult(reply: message, success: false);
    } finally {
      if (myRun == _runId) {
        _busy = false;
        _watchdog?.cancel();
      }
    }
  }

  /// Runs a plan the user approved (Plan and Plan & Execute cards).
  Future<AgentTurnResult> executePlan(ChatMessage message, AgentUi ui) async {
    final plan = message.plan;
    if (plan == null || !plan.awaitingApproval) {
      return const AgentTurnResult(reply: '');
    }
    if (_busy) {
      return const AgentTurnResult(reply: 'I am still working on the previous request.', success: false);
    }
    _busy = true;
    _cancelled = false;
    final myRun = ++_runId;
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(minutes: 15), cancel);
    try {
      await ctx.ensureLoaded();
      return await _runPlan(
        plan,
        ui,
        historyMode: plan.mode,
        askConfirmation: false,
        cacheKey: plan.goal,
      );
    } catch (e) {
      if (_cancelled) {
        plan.state = PlanState.cancelled;
        ui.refresh();
        return const AgentTurnResult(reply: 'Stopped.', success: false);
      }
      final text = 'Error: ${e.toString().replaceFirst('Exception: ', '')}';
      plan.state = PlanState.failed;
      ui.refresh();
      ui.addMessage(ChatMessage(role: 'assistant', content: text));
      return AgentTurnResult(reply: text, success: false);
    } finally {
      if (myRun == _runId) {
        _busy = false;
        _watchdog?.cancel();
      }
    }
  }

  /// Runs a goal immediately as an unattended job (scheduled tasks).
  Future<AgentTurnResult> runGoal(String goal, AgentMode mode, AgentUi ui) =>
      handle(goal, mode == AgentMode.planExecute ? AgentMode.auto : mode, ui);

  // ─── Chat & Think ──────────────────────────────────────────────────────

  static const String _chatPrompt = '''
You are PrivateAgent, a friendly and capable assistant that lives on the user's Android phone.
In Chat mode you only talk: you cannot operate the phone. If the user wants something done on the phone, tell them to switch to Auto or Plan & Execute mode.
Answer directly and naturally; use markdown when it helps. Use what you remember about the user when it is relevant, but never recite it.''';

  static const String _thinkPrompt = '''
You are PrivateAgent in Think mode, a careful reasoner on the user's Android phone. You cannot operate the phone in this mode.
First work through the problem step by step inside <thinking>...</thinking>: consider alternatives, check facts and arithmetic, and catch mistakes.
Then, after the closing tag, write the final answer: clear, well organised and as short as the question allows. Never mention the tags.''';

  Future<AgentTurnResult> _converse(String text, AgentUi ui, {required bool think}) async {
    final mode = think ? AgentMode.think : AgentMode.chat;
    final context = await ctx.contextBlock(text, includeAccounts: false);
    final system = '${think ? _thinkPrompt : _chatPrompt}\n\n$context';

    _history.add({'role': 'user', 'content': text});
    _trimHistory();
    final message = ui.addMessage(ChatMessage(role: 'assistant', content: '', mode: mode.id));

    final answer = await _stream(
      [
        {'role': 'system', 'content': system},
        ..._history,
      ],
      message,
      ui,
      keepReasoning: think,
      temperature: think ? math.min(ctx.ai.temperature, 0.7) : null,
      maxTokens: think ? math.max(ctx.ai.maxTokens, 4096) : null,
    );

    if (_cancelled) {
      if (message.content.trim().isEmpty) {
        ui.removeMessage(message);
      }
      return const AgentTurnResult(reply: 'Stopped.', success: false);
    }
    if (answer.trim().isEmpty) {
      throw Exception(
        'The model finished without a visible answer. Try again, or raise Max Tokens in Settings.',
      );
    }
    message.content = answer;
    ui.refresh();
    _history.add({'role': 'assistant', 'content': answer});
    _trimHistory();
    _learn(text, answer);
    return AgentTurnResult(reply: answer, speak: true);
  }

  /// Streams a completion into [message]. Returns the final visible answer.
  Future<String> _stream(
    List<Map<String, String>> messages,
    ChatMessage message,
    AgentUi ui, {
    bool keepReasoning = false,
    bool hideJson = false,
    double? temperature,
    int? maxTokens,
    void Function(String sentence)? onSentence,
  }) async {
    var raw = '';
    var sideReasoning = '';
    var spokenChars = 0;
    final stream = ctx.llm
        .stream(messages, temperature: temperature, maxTokens: maxTokens)
        .timeout(
          const Duration(seconds: 120),
          onTimeout: (sink) {
            sink.addError(TimeoutException('The model did not respond in time.'));
            sink.close();
          },
        );

    await for (final delta in stream) {
      if (_cancelled) break;
      raw += delta.content;
      sideReasoning += delta.reasoning;
      final split = ThinkParser.split(raw);
      final answer = split.answer;
      if (hideJson && _looksLikeAction(answer)) {
        message.content = 'Working on it…';
      } else {
        message.content = answer;
        if (onSentence != null && answer.trim().isNotEmpty) {
          final end = _sentenceEnd(answer, spokenChars);
          if (end > spokenChars) {
            final chunk = answer.substring(spokenChars, end).trim();
            spokenChars = end;
            if (chunk.isNotEmpty) {
              _spokeThisTurn = true;
              onSentence(chunk);
            }
          }
        }
      }
      if (keepReasoning) {
        final parts = [sideReasoning.trim(), split.reasoning.trim()].where((p) => p.isNotEmpty);
        message.reasoning = parts.join('\n\n');
        message.thinking = split.thinkingOpen || (answer.isEmpty && message.reasoning.isNotEmpty);
      }
      ui.refresh();
    }
    message.thinking = false;
    final finalAnswer = ThinkParser.split(raw).answer;
    if (onSentence != null && !_cancelled && !_looksLikeAction(finalAnswer) && finalAnswer.length > spokenChars) {
      final tail = finalAnswer.substring(spokenChars).trim();
      if (tail.isNotEmpty) {
        _spokeThisTurn = true;
        onSentence(tail);
      }
    }
    return finalAnswer;
  }

  /// End index of the last complete sentence in [text] after [from], or -1.
  static int _sentenceEnd(String text, int from) {
    if (from >= text.length) return -1;
    var last = -1;
    for (final m in RegExp(r'[.!?…]+["”)]?\s|\n').allMatches(text, from)) {
      last = m.end;
    }
    return last;
  }

  static bool _looksLikeAction(String answer) {
    final t = answer.trimLeft();
    return t.startsWith('{') || t.startsWith('```');
  }

  // ─── Plan / Plan & Execute ─────────────────────────────────────────────

  Future<AgentTurnResult> _propose(String text, AgentMode mode, AgentUi ui) async {
    final message = ui.addMessage(
      ChatMessage(role: 'assistant', content: 'Planning…', mode: mode.id),
    );
    _history.add({'role': 'user', 'content': text});
    _trimHistory();

    final plan = await Planner(ctx).createPlan(text, mode: mode.id);
    if (_cancelled) {
      ui.removeMessage(message);
      return const AgentTurnResult(reply: 'Stopped.', success: false);
    }
    message.plan = plan;
    message.content =
        'Here is the plan. Nothing has been done yet: edit it if you like and tap **Run this plan** when ready.';
    ui.refresh();
    final summary = plan.summary.isEmpty ? plan.goal : plan.summary;
    _history.add({'role': 'assistant', 'content': 'I proposed a plan: $summary'});
    _trimHistory();
    return AgentTurnResult(reply: message.content, speak: false);
  }

  Future<AgentTurnResult> _runPlan(
    Plan plan,
    AgentUi ui, {
    required String historyMode,
    required bool askConfirmation,
    String? cacheKey,
    bool fromCache = false,
  }) async {
    final runner = PlanRunner(
      ctx: ctx,
      onChanged: ui.refresh,
      onProgress: ui.onProgress,
      confirmStep: (askConfirmation && !_unattended && ctx.prefs.confirmSensitive) ? ui.confirmStep : null,
    );
    _runner = runner;
    PlanRunResult result;
    try {
      result = await runner.run(plan, historyMode: historyMode);
    } finally {
      _runner = null;
    }
    ui.refresh();

    if (cacheKey != null) {
      if (result.success) {
        await PlanCache.instance.remember(cacheKey, plan);
      } else if (fromCache && !result.cancelled) {
        await PlanCache.instance.recordResult(cacheKey, success: false);
      }
    }

    final reply = result.reply;
    ui.addMessage(
      ChatMessage(
        role: 'assistant',
        content: result.success ? reply : '⚠️ $reply',
        mode: historyMode,
        actionResult: AgentActionResult(
          actionType: 'plan_and_execute',
          success: result.success,
          details: reply,
        ),
      ),
    );
    _history.add({'role': 'assistant', 'content': reply});
    _trimHistory();
    return AgentTurnResult(
      reply: reply,
      usedDevice: true,
      success: result.success,
      speak: true,
    );
  }

  // ─── Auto ──────────────────────────────────────────────────────────────

  static const String _autoPrompt = '''
You are PrivateAgent, an autonomous assistant that lives on the user's Android phone. You can chat, reason, remember things, and operate the phone.

Decide how to handle each message:
1. Conversation, questions, writing, advice: reply with plain text (markdown allowed). No JSON.
2. Anything that needs the phone or an automation: reply with ONLY one JSON object (no code fences, no other text):
{"action": "action_name", "params": {"key": "value"}, "response": "one short sentence telling the user what you are doing"}

SIMPLE ACTIONS (one step):
- open_app {"app_name"}: only when the user just wants an app opened
- make_call {"contact_name"} or {"phone_number"}
- send_sms {"contact_name" or "phone_number", "message"}
- search_contact {"query"}
- set_alarm {"hour", "minute", "label"} (24-hour)
- set_timer {"seconds", "label"}
- set_volume {"level"} and set_brightness {"level"} (0-100)
- open_url {"url"}
- send_email {"to", "subject", "body"}
- read_screen {}
- press_back {}

AUTONOMOUS ACTIONS:
- execute_task {"goal"}: ONE self-contained job inside one app or flow (for example "search YouTube for cats").
- plan_and_execute {"goal"}: a bigger job with several stages or apps. The agent writes a plan, runs it step by step, verifies each step and recovers from problems.

MEMORY AND AUTOMATION:
- remember {"fact": "...", "section": "About the user | Preferences | Facts & notes | Routines & habits"}: store something durable about the user. Never store passwords, PINs or card numbers.
- run_skill {"name": "...", "goal": "..."}: run one of the user's saved skills (listed below when available).
- schedule_task {"goal": "...", "when": "YYYY-MM-DD HH:MM", "repeat": "none | daily | weekdays | weekly"}: run a task later. "when" is the user's local time in 24-hour format; work it out from the current date and time.

RULES:
- If a request has several steps ("open X and do Y"), use execute_task or plan_and_execute, never open_app.
- Prefer execute_task (one app, one flow) and use plan_and_execute only when the job truly spans several different apps. Both are slower when they are used unnecessarily.
- Ask a short clarifying question in plain text instead of guessing when a required detail (who, what, when) is missing.
- Do not claim you did something unless you used an action.
- When the request needs something WRITTEN (a message, reply, caption, summary, explanation...) as part of a device action, write the actual, complete content yourself and put it in the goal — do not shorten it to the topic words. "send mom information about how AI is useful on WhatsApp" is not the goal "send mom info about how AI is useful"; the goal must contain the full message you composed, e.g. execute_task {"goal": "Open WhatsApp, open the chat with Mom, and send this message: \\"AI is useful because it can...\\" [your full composed message]"}. The step that actually types the message (later, inside execute_task) will only have your composed text to work with — if you don't write it here, it never gets written.''';

  static const String _voiceAddendum = '''
\nVOICE CALL: the user is talking to you on a hands-free voice call and hears your replies. Answer in one or two short spoken sentences: no markdown, lists, emojis or links. When the user says goodbye or signals they are finished (bye, that's all, hang up, talk later, thanks that's it), reply with ONLY {"action": "end_call", "params": {}, "response": "a short goodbye"}. Never end the call otherwise.''';

  static const String _unattendedAddendum = '''
\nSCHEDULED TASK: this request comes from a schedule and runs unattended, nobody is there to answer questions. Do it now with an action (execute_task or plan_and_execute for anything on the phone). Do not ask for confirmation. If it is an information request, use an action to read the answer from the phone or reply directly.''';

  Future<AgentTurnResult> _auto(String text, AgentUi ui) async {
    final context = await ctx.contextBlock(text, includeSkillCatalog: true);
    final system =
        '$_autoPrompt${_voiceCall ? _voiceAddendum : ''}${_unattended ? _unattendedAddendum : ''}\n\n$context';

    _history.add({'role': 'user', 'content': text});
    _trimHistory();
    final message = ui.addMessage(ChatMessage(role: 'assistant', content: '', mode: AgentMode.auto.id));

    final answer = await _stream(
      [
        {'role': 'system', 'content': system},
        ..._history,
      ],
      message,
      ui,
      hideJson: true,
      onSentence: (_voiceCall && ui.speak != null) ? ui.speak : null,
    );

    if (_cancelled) {
      ui.removeMessage(message);
      return const AgentTurnResult(reply: 'Stopped.', success: false);
    }
    if (answer.trim().isEmpty) {
      throw Exception('The model finished without a visible answer. Try again.');
    }

    final action = ctx.ai.parseAction(answer);
    if (action == null) {
      message.content = answer;
      ui.refresh();
      _history.add({'role': 'assistant', 'content': answer});
      _trimHistory();
      _learn(text, answer);
      return AgentTurnResult(reply: answer, speak: true, spoken: _spokeThisTurn);
    }

    ui.removeMessage(message);
    _history.add({
      'role': 'assistant',
      'content': '[Used action ${action.action}] ${action.response}'.trim(),
    });
    _trimHistory();
    final result = await _dispatch(action, text, ui);
    _learn(text, result.reply);
    return result;
  }

  Future<AgentTurnResult> _dispatch(AgentAction action, String userText, AgentUi ui) async {
    final params = action.params;
    switch (action.action) {
      case 'end_call':
        {
          if (!_voiceCall) return _reply(ui, action.response.isEmpty ? 'Okay.' : action.response);
          final bye = action.response.isEmpty ? 'Goodbye!' : action.response;
          return AgentTurnResult(reply: bye, speak: true, endCall: true);
        }
      case 'execute_task':
        {
          final goal = JsonUtils.str(params['goal'], userText);
          _say(ui, action.response);
          return _runPlanOnDevice(
            Plan.single(goal, mode: 'auto'),
            ui,
            askConfirmation: false,
            cacheKey: userText,
          );
        }
      case 'plan_and_execute':
        {
          final goal = JsonUtils.str(params['goal'], userText);
          return _planAndExecute(goal, action.response, ui, cacheKey: userText);
        }
      case 'run_skill':
        {
          final skill = ctx.skills.byName(JsonUtils.str(params['name']));
          if (skill == null) {
            return _reply(ui, 'I could not find a skill with that name. You can manage skills from the menu.');
          }
          await ctx.skills.recordUse(skill.id);
          final goal = JsonUtils.str(params['goal'], userText);
          return _planAndExecute(
            '$goal (use the skill "${skill.name}")',
            action.response,
            ui,
            cacheKey: userText,
          );
        }
      case 'remember':
        return _remember(action, ui);
      case 'schedule_task':
        return _schedule(action, userText, ui);
      default:
        return _directAction(action, ui, userText);
    }
  }

  void _say(AgentUi ui, String text) {
    if (text.trim().isEmpty) return;
    ui.addMessage(ChatMessage(role: 'assistant', content: text.trim(), mode: AgentMode.auto.id));
    if (_voiceCall) ui.speak?.call(text.trim());
  }

  static final RegExp _openIntent = RegExp(
    r"^\s*(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?(.{2,30}?)(?:\s+app)?\s*[.!]?\s*$",
    caseSensitive: false,
  );
  static final RegExp _compound = RegExp(
    r'\b(and|then|in|on|to|for|with|from|at|inside|search|play|send|message|call)\b',
    caseSensitive: false,
  );

  /// A skill the user (or the agent) saved whose name or trigger phrase is
  /// literally in the request runs immediately, with its own instructions
  /// handed to the planner — no model call to decide whether to use it.
  Future<AgentTurnResult?> _tryUserSkill(String text, AgentMode mode, AgentUi ui) async {
    final skill = ctx.skills.strongMatch(text);
    if (skill == null) return null;
    await ctx.skills.recordUse(skill.id);
    _history.add({'role': 'user', 'content': text});
    _trimHistory();
    return _planAndExecute(
      '$text (use the skill "${skill.name}": ${skill.instructions})',
      'Using "${skill.name}"…',
      ui,
      mode: mode.id,
      askConfirmation: false,
      cacheKey: text,
    );
  }

  /// A request that matches a learned template ("search <x> on youtube")
  /// runs straight from the recorded taps with the new value, no model call.
  Future<AgentTurnResult?> _tryTemplate(String text, AgentMode mode, AgentUi ui) async {
    final match = await SkillMemoryService().matchSkill(text);
    if (match == null || match.value == null || !match.skill.isReliable) return null;
    _history.add({'role': 'user', 'content': text});
    _trimHistory();
    return _runPlanOnDevice(
      Plan.single(text, mode: mode.id),
      ui,
      askConfirmation: false,
      mode: mode.id,
    );
  }

  /// Classifies search/lookup requests (YouTube/Facebook/Instagram) via LLM,
  /// runs in parallel to the normal automation pipeline. The classification
  /// takes ~2 seconds (one quick model call), and by the time the result
  /// comes back, the link can be opened while the normal automation is
  /// still planning. This is about 2x faster than the full automation loop,
  /// so it *feels* responsive rather than stuck.
  ///
  /// Returns a result immediately if a link was opened successfully;
  /// otherwise returns null to let the normal automation path handle it.
  Future<AgentTurnResult?> _tryQuickLink(String text, AgentUi ui) async {
    // Heuristic: if it doesn't mention a platform or search word, skip the LLM call
    if (!QuickLinkDetector.looksLikeSearch(text)) return null;

    // Ask the LLM to classify: is this a search for X on YouTube/Facebook/Instagram?
    // Format the request as JSON that's easy for the model to respond to.
    final classifyPrompt = '''Classify this request. Respond with ONLY a JSON object, no other text:
{
  "is_plain_search": true/false,
  "platform": "youtube" | "facebook" | "instagram" | "",
  "query": "search term or handle or hashtag, or empty string",
  "is_profile": true/false,
  "is_hashtag": true/false,
  "confidence": 0.0 to 1.0,
  "needs_further_automation": "empty string OR description of what to do after the link, e.g. 'tap first result and watch'"
}

Request: "$text"

Guidelines:
- is_plain_search: true only if this is ONLY a search/lookup on that platform, nothing else (no sending, posting, liking, following, etc.)
- platform: which platform (lowercase). Empty if unclear or multiple platforms.
- query: the search term, handle, or hashtag (without # or @). Empty if unclear.
- is_profile: true if looking for a specific person's profile (Instagram).
- is_hashtag: true if looking for a hashtag (Instagram).
- confidence: 0.0 if unclear, 1.0 if certain.
- needs_further_automation: if the request is "search and then X", put "X" here; otherwise empty string.

Examples:
- "search youtube for cats" → is_plain_search: true, platform: "youtube", query: "cats", confidence: 1.0
- "look up rivaldo on instagram" → is_plain_search: true, platform: "instagram", query: "rivaldo", is_profile: true, confidence: 1.0
- "search facebook for coffee shops" → is_plain_search: true, platform: "facebook", query: "coffee shops", confidence: 1.0
- "search youtube and watch the first result" → is_plain_search: false, needs_further_automation: "watch the first result"
- "send me a link to youtube" → is_plain_search: false, confidence: 0
- "what is machine learning" → is_plain_search: false, confidence: 0''';

    try {
      final classification = await _classifyForQuickLink(classifyPrompt);
      if (!classification.isValid) return null;

      final url = classification.buildUrl();
      if (url == null) return null;

      // Open the URL
      final result = await ctx.actions.execute(
        AgentAction(action: 'open_url', params: {'url': url}, response: ''),
      );
      final details = (result.details ?? '').trim().toLowerCase();
      if (!result.success || details.startsWith('error') || details.startsWith('cannot')) {
        return null; // let the model work it out instead
      }

      // Log the result
      final reply = 'Here you go: $url';
      _history.add({'role': 'user', 'content': text});
      _history.add({'role': 'assistant', 'content': reply});
      _trimHistory();
      ui.addMessage(
        ChatMessage(role: 'assistant', content: reply, actionResult: result, mode: AgentMode.auto.id),
      );
      return AgentTurnResult(reply: reply, usedDevice: true, speak: true);
    } catch (_) {
      // On any error (network, parsing, etc.), fall through to normal automation
      return null;
    }
  }

  /// Calls the LLM to classify a search request. Returns a parsed
  /// [QuickLinkClassification]; safe to call and handles parsing errors.
  Future<QuickLinkClassification> _classifyForQuickLink(String prompt) async {
    try {
      final resp = await ctx.ai.sendMessage(
        _classifySystemPrompt,
        prompt,
        isAgentMode: true,
      );
      final text = resp.trim();
      // Parse the JSON response
      // Try to extract JSON from markdown code fences if present
      var jsonText = text;
      if (text.contains('```json')) {
        final start = text.indexOf('```json') + 7;
        final end = text.indexOf('```', start);
        if (end > start) jsonText = text.substring(start, end).trim();
      } else if (text.contains('```')) {
        final start = text.indexOf('```') + 3;
        final end = text.indexOf('```', start);
        if (end > start) jsonText = text.substring(start, end).trim();
      }

      // Simple JSON parsing without dependencies
      final obj = _parseJson(jsonText);
      if (obj == null) return QuickLinkClassification();

      return QuickLinkClassification(
        platform: (obj['platform'] as String?)?.trim() ?? '',
        query: (obj['query'] as String?)?.trim() ?? '',
        isSearch: obj['is_plain_search'] == true,
        isProfile: obj['is_profile'] == true,
        isHashtag: obj['is_hashtag'] == true,
        confidence: (obj['confidence'] as num?)?.toDouble() ?? 0.0,
        furtherGoal: (obj['needs_further_automation'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return QuickLinkClassification();
    }
  }

  /// Minimal JSON parser for the classification response (avoids adding
  /// a dependency just for this one call).
  static Map<String, dynamic>? _parseJson(String text) {
    try {
      final trimmed = text.trim();
      if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null;

      final result = <String, dynamic>{};
      var i = 1; // Skip opening {
      while (i < trimmed.length) {
        final char = trimmed[i];
        if (char == '}') break;
        if (char == '"') {
          // Key
          final keyStart = i + 1;
          var j = keyStart;
          while (j < trimmed.length && trimmed[j] != '"') j++;
          if (j >= trimmed.length) return null;
          final key = trimmed.substring(keyStart, j);
          i = j + 1;

          // Skip :
          while (i < trimmed.length && (trimmed[i] == ' ' || trimmed[i] == ':')) i++;

          // Value
          if (i >= trimmed.length) return null;
          final valueChar = trimmed[i];
          if (valueChar == '"') {
            // String value
            final valStart = i + 1;
            var k = valStart;
            while (k < trimmed.length && trimmed[k] != '"') {
              if (trimmed[k] == '\\') k++; // Skip escaped chars
              k++;
            }
            if (k >= trimmed.length) return null;
            final val = trimmed.substring(valStart, k);
            result[key] = val;
            i = k + 1;
          } else if (valueChar == 't' || valueChar == 'f') {
            // Boolean
            if (trimmed.substring(i).startsWith('true')) {
              result[key] = true;
              i += 4;
            } else if (trimmed.substring(i).startsWith('false')) {
              result[key] = false;
              i += 5;
            }
          } else if (valueChar == '-' || (valueChar.codeUnitAt(0) >= 48 && valueChar.codeUnitAt(0) <= 57)) {
            // Number
            var k = i;
            while (k < trimmed.length && (trimmed[k] == '-' || trimmed[k] == '.' || (trimmed[k].codeUnitAt(0) >= 48 && trimmed[k].codeUnitAt(0) <= 57))) k++;
            final numStr = trimmed.substring(i, k);
            result[key] = double.tryParse(numStr) ?? int.tryParse(numStr);
            i = k;
          }

          // Skip to next comma or close
          while (i < trimmed.length && trimmed[i] != ',' && trimmed[i] != '}') i++;
          if (i < trimmed.length && trimmed[i] == ',') i++;
        } else {
          i++;
        }
      }
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  static const String _classifySystemPrompt = '''You are a classifier for search requests. Always respond with ONLY valid JSON, no other text, no markdown fences.''';


  /// "open Instagram": opens the app straight away, no model call.
  Future<AgentTurnResult?> _tryLocalIntent(String text, AgentUi ui) async {
    final m = _openIntent.firstMatch(text);
    if (m == null) return null;
    final name = (m.group(1) ?? '').trim();
    if (name.isEmpty || _compound.hasMatch(name)) return null;

    final action = AgentAction(
      action: 'open_app',
      params: {'app_name': name},
      response: 'Opening $name.',
    );
    final result = await AppOpener.open(ctx.actions, ctx.ai, name, onProgress: ui.onProgress);
    final details = (result.details ?? '').trim();
    final failed = !result.success ||
        RegExp(r'^(error|could not|cannot|can.t|no app|not found|failed|unable)', caseSensitive: false)
            .hasMatch(details);
    if (failed) return null; // let the model work it out

    final reply = 'Opening $name.';
    _history.add({'role': 'user', 'content': text});
    _history.add({'role': 'assistant', 'content': reply});
    _trimHistory();
    ui.addMessage(
      ChatMessage(role: 'assistant', content: reply, actionResult: result, mode: AgentMode.auto.id),
    );
    return AgentTurnResult(reply: reply, usedDevice: true, speak: true);
  }

  AgentTurnResult _reply(AgentUi ui, String text, {bool success = true}) {
    ui.addMessage(ChatMessage(role: 'assistant', content: text, mode: AgentMode.auto.id));
    return AgentTurnResult(reply: text, success: success, speak: true);
  }

  Future<AgentTurnResult> _planAndExecute(
    String goal,
    String announcement,
    AgentUi ui, {
    String mode = 'auto',
    bool askConfirmation = true,
    String? cacheKey,
  }) async {
    _say(ui, announcement);
    if (mode == 'planExecute') {
      _history.add({'role': 'user', 'content': goal});
      _trimHistory();
    }
    final plan = await Planner(ctx).createPlan(goal, mode: mode);
    if (_cancelled) return const AgentTurnResult(reply: 'Stopped.', success: false);
    return _runPlanOnDevice(
      plan,
      ui,
      askConfirmation: askConfirmation,
      mode: mode,
      cacheKey: cacheKey,
    );
  }

  Future<AgentTurnResult> _runPlanOnDevice(
    Plan plan,
    AgentUi ui, {
    required bool askConfirmation,
    String mode = 'auto',
    String? cacheKey,
    bool fromCache = false,
  }) {
    plan.state = PlanState.running;
    ui.addMessage(
      ChatMessage(
        role: 'assistant',
        content: fromCache
            ? 'Running a saved routine…'
            : (plan.steps.length > 1 ? 'Working through ${plan.steps.length} steps…' : 'Working on it…'),
        plan: plan,
        mode: mode,
      ),
    );
    return _runPlan(
      plan,
      ui,
      historyMode: mode,
      askConfirmation: askConfirmation,
      cacheKey: cacheKey,
      fromCache: fromCache,
    );
  }

  /// Runs a request that succeeded before, without any planning calls.
  Future<AgentTurnResult> _runCached(
    CachedRoutine routine,
    String text,
    AgentMode mode,
    AgentUi ui,
  ) async {
    _history.add({'role': 'user', 'content': text});
    _trimHistory();
    final plan = routine.toPlan(mode.id);
    return _runPlanOnDevice(
      plan,
      ui,
      askConfirmation: mode == AgentMode.auto,
      mode: mode.id,
      cacheKey: text,
      fromCache: true,
    );
  }

  static const Set<String> _cacheableActions = {
    'open_app',
    'open_url',
    'set_volume',
    'set_brightness',
    'search_contact',
  };

  Future<AgentTurnResult> _directAction(AgentAction action, AgentUi ui, String userText) async {
    final result = await ctx.actions.execute(
      action,
      aiService: ctx.ai,
      onProgress: ui.onProgress,
    );
    final details = result.details ?? '';
    final text = result.success
        ? (action.response.isNotEmpty ? action.response : (details.isEmpty ? 'Done.' : details))
        : (action.response.isNotEmpty ? '${action.response}\n\n⚠️ $details' : '⚠️ $details');
    ui.addMessage(
      ChatMessage(role: 'assistant', content: text, actionResult: result, mode: AgentMode.auto.id),
    );
    if (result.success && _cacheableActions.contains(action.action)) {
      final step = PlanStep(
        id: 's1',
        title: userText,
        kind: 'action',
        action: action.action,
        params: Map<String, dynamic>.from(action.params),
        status: StepStatus.done,
      );
      await PlanCache.instance.remember(
        userText,
        Plan(goal: userText, summary: userText, mode: 'auto', steps: [step]),
      );
    }
    try {
      await NotificationService().showTaskCompleteNotification(
        result.success ? 'Task Completed' : 'Task Failed',
        details.isEmpty ? 'Agent finished its goal.' : (details.length > 160 ? details.substring(0, 160) : details),
      );
    } catch (_) {}
    return AgentTurnResult(reply: text, usedDevice: true, success: result.success, speak: true);
  }

  Future<AgentTurnResult> _remember(AgentAction action, AgentUi ui) async {
    final fact = JsonUtils.str(action.params['fact']);
    final result = await ctx.memory.addFact(JsonUtils.str(action.params['section']), fact);
    final text = switch (result) {
      MemoryAddResult.added => action.response.isNotEmpty ? action.response : 'Got it, I will remember that.',
      MemoryAddResult.duplicate => 'I already knew that.',
      MemoryAddResult.sensitive =>
        'That looks like a secret, so I did not put it in memory. Save it in Accounts, where it is encrypted.',
      MemoryAddResult.empty => 'What should I remember?',
    };
    return _reply(ui, text);
  }

  Future<AgentTurnResult> _schedule(AgentAction action, String userText, AgentUi ui) async {
    final goal = JsonUtils.str(action.params['goal'], userText);
    final when = SchedulerService.parseWhen(JsonUtils.str(action.params['when']));
    var repeat = JsonUtils.str(action.params['repeat'], 'none').toLowerCase();
    if (!const ['none', 'daily', 'weekdays', 'weekly'].contains(repeat)) repeat = 'none';
    if (when == null || (repeat == 'none' && !when.isAfter(DateTime.now()))) {
      return _reply(ui, 'I could not work out a future time for that. When exactly should it run?', success: false);
    }
    final task = await SchedulerService.instance.add(goal: goal, when: when, repeat: repeat, mode: 'auto');
    final next = task.nextRun;
    final label = next == null ? 'later' : DateFormat('EEE d MMM, HH:mm').format(next);
    return _reply(
      ui,
      'Scheduled: "$goal" for $label${repeat == 'none' ? '' : ' (${task.repeatLabel.toLowerCase()})'}. You can manage it under Schedules.',
    );
  }

  // ─── Learning ──────────────────────────────────────────────────────────

  void _learn(String userText, String reply) {
    if (!ctx.prefs.autoLearnMemory) return;
    if (!MemoryService.worthLearning(userText)) return;
    unawaited(ctx.memory.learnFromTurn(ctx.llm, userText: userText, assistantText: reply));
  }
}
