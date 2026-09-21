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
import 'plan_runner.dart';
import 'planner.dart';
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

  const AgentUi({
    required this.addMessage,
    required this.refresh,
    required this.removeMessage,
    required this.confirmStep,
    required this.onProgress,
  });
}

class AgentTurnResult {
  final String reply;
  final bool usedDevice;
  final bool success;

  /// Whether the reply is worth reading aloud.
  final bool speak;

  const AgentTurnResult({
    required this.reply,
    this.usedDevice = false,
    this.success = true,
    this.speak = false,
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

  void cancel() {
    _cancelled = true;
    _runner?.cancel();
    ctx.actions.cancelTask();
  }

  // ─── Entry points ──────────────────────────────────────────────────────

  Future<AgentTurnResult> handle(String rawText, AgentMode mode, AgentUi ui) async {
    final text = rawText.trim();
    if (text.isEmpty) return const AgentTurnResult(reply: '');
    if (_busy) {
      return const AgentTurnResult(reply: 'I am still working on the previous request.', success: false);
    }
    _busy = true;
    _cancelled = false;
    try {
      await ctx.ensureLoaded();

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
        case AgentMode.planExecute:
          return await _propose(text, mode, ui);
        case AgentMode.auto:
          return await _auto(text, ui);
      }
    } catch (e) {
      final message = 'Error: ${e.toString().replaceFirst('Exception: ', '')}';
      ui.addMessage(ChatMessage(role: 'assistant', content: message, mode: mode.id));
      return AgentTurnResult(reply: message, success: false);
    } finally {
      _busy = false;
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
    try {
      await ctx.ensureLoaded();
      return await _runPlan(plan, ui, historyMode: plan.mode, askConfirmation: false);
    } catch (e) {
      final text = 'Error: ${e.toString().replaceFirst('Exception: ', '')}';
      plan.state = PlanState.failed;
      ui.refresh();
      ui.addMessage(ChatMessage(role: 'assistant', content: text));
      return AgentTurnResult(reply: text, success: false);
    } finally {
      _busy = false;
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
  }) async {
    var raw = '';
    var sideReasoning = '';
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
      }
      if (keepReasoning) {
        final parts = [sideReasoning.trim(), split.reasoning.trim()].where((p) => p.isNotEmpty);
        message.reasoning = parts.join('\n\n');
        message.thinking = split.thinkingOpen || (answer.isEmpty && message.reasoning.isNotEmpty);
      }
      ui.refresh();
    }
    message.thinking = false;
    return ThinkParser.split(raw).answer;
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
    message.content = mode == AgentMode.plan
        ? 'Here is the plan. Nothing has been done yet: run it whenever you like.'
        : 'Here is my plan. Review or edit it, then tap **Approve & run**.';
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
  }) async {
    final runner = PlanRunner(
      ctx: ctx,
      onChanged: ui.refresh,
      onProgress: ui.onProgress,
      confirmStep: (askConfirmation && ctx.prefs.confirmSensitive) ? ui.confirmStep : null,
    );
    _runner = runner;
    PlanRunResult result;
    try {
      result = await runner.run(plan, historyMode: historyMode);
    } finally {
      _runner = null;
    }
    ui.refresh();

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
- Ask a short clarifying question in plain text instead of guessing when a required detail (who, what, when) is missing.
- Do not claim you did something unless you used an action.''';

  Future<AgentTurnResult> _auto(String text, AgentUi ui) async {
    final context = await ctx.contextBlock(text, includeSkillCatalog: true);
    final system = '$_autoPrompt\n\n$context';

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
      return AgentTurnResult(reply: answer, speak: true);
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
      case 'execute_task':
        {
          final goal = JsonUtils.str(params['goal'], userText);
          _say(ui, action.response);
          return _runPlanOnDevice(Plan.single(goal, mode: 'auto'), ui, askConfirmation: false);
        }
      case 'plan_and_execute':
        {
          final goal = JsonUtils.str(params['goal'], userText);
          return _planAndExecute(goal, action.response, ui);
        }
      case 'run_skill':
        {
          final skill = ctx.skills.byName(JsonUtils.str(params['name']));
          if (skill == null) {
            return _reply(ui, 'I could not find a skill with that name. You can manage skills from the menu.');
          }
          await ctx.skills.recordUse(skill.id);
          final goal = JsonUtils.str(params['goal'], userText);
          return _planAndExecute('$goal (use the skill "${skill.name}")', action.response, ui);
        }
      case 'remember':
        return _remember(action, ui);
      case 'schedule_task':
        return _schedule(action, userText, ui);
      default:
        return _directAction(action, ui);
    }
  }

  void _say(AgentUi ui, String text) {
    if (text.trim().isEmpty) return;
    ui.addMessage(ChatMessage(role: 'assistant', content: text.trim(), mode: AgentMode.auto.id));
  }

  AgentTurnResult _reply(AgentUi ui, String text, {bool success = true}) {
    ui.addMessage(ChatMessage(role: 'assistant', content: text, mode: AgentMode.auto.id));
    return AgentTurnResult(reply: text, success: success, speak: true);
  }

  Future<AgentTurnResult> _planAndExecute(String goal, String announcement, AgentUi ui) async {
    _say(ui, announcement);
    final plan = await Planner(ctx).createPlan(goal, mode: 'auto');
    if (_cancelled) return const AgentTurnResult(reply: 'Stopped.', success: false);
    return _runPlanOnDevice(plan, ui, askConfirmation: true);
  }

  Future<AgentTurnResult> _runPlanOnDevice(
    Plan plan,
    AgentUi ui, {
    required bool askConfirmation,
  }) {
    plan.state = PlanState.running;
    ui.addMessage(
      ChatMessage(
        role: 'assistant',
        content: plan.steps.length > 1 ? 'Working through ${plan.steps.length} steps…' : 'Working on it…',
        plan: plan,
        mode: AgentMode.auto.id,
      ),
    );
    return _runPlan(plan, ui, historyMode: 'auto', askConfirmation: askConfirmation);
  }

  Future<AgentTurnResult> _directAction(AgentAction action, AgentUi ui) async {
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
