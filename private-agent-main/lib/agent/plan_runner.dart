import 'dart:async';
import '../models/agent_action.dart';
import '../services/notification_service.dart';
import '../services/task_executor.dart';
import '../services/task_history_logger.dart';
import 'agent_context.dart';
import 'app_opener.dart';
import 'json_utils.dart';
import 'memory_service.dart';
import 'plan.dart';
import 'planner.dart';

class PlanRunResult {
  final bool success;
  final bool cancelled;

  /// What to tell the user: the answer, or an explanation of what went wrong.
  final String reply;

  const PlanRunResult({
    required this.success,
    required this.cancelled,
    required this.reply,
  });
}

class _StepOutcome {
  final bool ok;
  final String message;

  /// True when retrying or re-planning cannot help (for example the
  /// accessibility service is switched off).
  final bool fatal;

  const _StepOutcome(this.ok, this.message, {this.fatal = false});
}

/// Runs a [Plan] step by step around the existing screen-automation engine:
/// every "ui" step is handed to [TaskExecutor] unchanged, then verified,
/// retried and, if necessary, the remaining plan is rewritten.
class PlanRunner {
  final AgentContext ctx;
  final Planner planner;

  /// Called whenever the plan (statuses, results, steps) changed.
  final void Function() onChanged;

  /// Human-readable progress lines.
  final void Function(String message) onProgress;

  /// Asks the user before a sensitive step. Null disables confirmation.
  final Future<bool> Function(PlanStep step)? confirmStep;

  PlanRunner({
    required this.ctx,
    required this.onChanged,
    required this.onProgress,
    this.confirmStep,
  }) : planner = Planner(ctx);

  bool _cancelled = false;
  TaskExecutor? _executor;
  int _tokens = 0;
  final Map<String, String> _hints = {};

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _executor?.cancel();
  }

  Future<PlanRunResult> run(Plan plan, {String historyMode = 'planExecute'}) async {
    _cancelled = false;
    _tokens = 0;
    _hints.clear();
    await ctx.ensureLoaded();

    plan.state = PlanState.running;
    onChanged();

    var i = 0;
    var replans = 0;
    var finalAnswer = '';
    String? failure;
    final maxRetries = ctx.prefs.maxRetries;

    while (i < plan.steps.length) {
      if (_cancelled) break;
      final step = plan.steps[i];
      if (step.status == StepStatus.done || step.status == StepStatus.skipped) {
        i++;
        continue;
      }

      step.status = StepStatus.running;
      step.attempts += 1;
      onChanged();

      if (step.sensitive && confirmStep != null && step.attempts == 1) {
        final approved = await confirmStep!(step);
        if (_cancelled) break;
        if (!approved) {
          step.status = StepStatus.skipped;
          step.result = 'Skipped: not approved';
          onChanged();
          i++;
          continue;
        }
      }

      onProgress('Step ${i + 1}/${plan.steps.length}: ${step.title}');
      final outcome = await _runStep(plan, step, i);
      if (_cancelled) break;

      if (outcome.ok) {
        step.status = StepStatus.done;
        step.result = _clip(outcome.message, 500);
        if (step.kind == 'respond') finalAnswer = outcome.message;
        onChanged();
        i++;
        continue;
      }

      step.result = _clip(outcome.message, 300);
      onChanged();

      if (outcome.fatal) {
        step.status = StepStatus.failed;
        failure = outcome.message;
        onChanged();
        break;
      }

      // The screen may already be past this step (the previous step or the
      // agent itself went further). Check before repeating anything.
      final reached = await _reconcile(plan, i);
      if (_cancelled) break;
      if (reached > i) {
        for (var k = i; k < reached && k < plan.steps.length; k++) {
          plan.steps[k].status = StepStatus.done;
          plan.steps[k].result = 'Already done on screen';
        }
        onChanged();
        i = reached;
        continue;
      }

      if (step.attempts <= maxRetries) {
        _hints[step.id] = outcome.message;
        onProgress('Retrying step ${i + 1} with a different approach…');
        continue;
      }

      step.status = StepStatus.failed;
      onChanged();

      if (replans < ctx.prefs.maxReplans) {
        replans++;
        onProgress('Re-planning after a problem…');
        final screen = await _screenSnapshot(plan.goal);
        List<PlanStep>? fresh;
        try {
          fresh = await planner.replan(
            plan,
            step,
            outcome.message,
            screen: screen,
            startIndex: plan.steps.length,
          );
        } catch (_) {
          fresh = null;
        }
        if (fresh != null && fresh.isNotEmpty) {
          plan.steps.removeRange(i + 1, plan.steps.length);
          plan.steps.addAll(fresh);
          onChanged();
          i++;
          continue;
        }
      }

      failure = 'Step "${step.title}" failed: ${_clip(outcome.message, 200)}';
      break;
    }

    return _finish(plan, historyMode, finalAnswer, failure);
  }

  Future<PlanRunResult> _finish(
    Plan plan,
    String historyMode,
    String finalAnswer,
    String? failure,
  ) async {
    final notifier = NotificationService();

    if (_cancelled) {
      for (final s in plan.steps) {
        if (s.status == StepStatus.running) s.status = StepStatus.pending;
      }
      plan.state = PlanState.cancelled;
      plan.outcome = 'Stopped.';
      onChanged();
      await TaskHistoryLogger.logTask(
        plan.goal,
        'Cancelled',
        _tokens,
        plan.steps.length,
        plan.traceLines(),
        mode: historyMode,
        plan: plan.toJson(),
      );
      return const PlanRunResult(success: false, cancelled: true, reply: 'Stopped.');
    }

    if (failure != null) {
      plan.state = PlanState.failed;
      final done = plan.doneCount;
      plan.outcome =
          'I could not finish this. $failure\nCompleted $done of ${plan.steps.length} steps.';
      onChanged();
      await TaskHistoryLogger.logTask(
        plan.goal,
        'Failed',
        _tokens,
        plan.steps.length,
        plan.traceLines(),
        mode: historyMode,
        plan: plan.toJson(),
      );
      await notifier.showTaskCompleteNotification('Task failed', _clip(failure, 160));
      return PlanRunResult(success: false, cancelled: false, reply: plan.outcome);
    }

    plan.state = PlanState.done;
    plan.outcome = _composeSuccessReply(plan, finalAnswer);
    onChanged();
    await TaskHistoryLogger.logTask(
      plan.goal,
      'Success',
      _tokens,
      plan.steps.length,
      plan.traceLines(),
      mode: historyMode,
      plan: plan.toJson(),
    );
    await notifier.showTaskCompleteNotification(
      'Task completed',
      _clip(plan.summary.isEmpty ? plan.goal : plan.summary, 160),
    );
    return PlanRunResult(success: true, cancelled: false, reply: plan.outcome);
  }

  String _composeSuccessReply(Plan plan, String finalAnswer) {
    if (finalAnswer.trim().isNotEmpty) return finalAnswer.trim();
    final headline = plan.summary.isEmpty ? plan.goal : plan.summary;
    for (final s in plan.steps.reversed) {
      final r = s.result.trim();
      if (s.status == StepStatus.done &&
          s.kind == 'ui' &&
          r.length > 12 &&
          r.toLowerCase() != headline.toLowerCase()) {
        return 'Done: $headline\n\n$r';
      }
    }
    return 'Done: $headline';
  }

  // ─── Step execution ────────────────────────────────────────────────────

  Future<_StepOutcome> _runStep(Plan plan, PlanStep step, int index) async {
    try {
      switch (step.kind) {
        case 'respond':
          return await _respond(plan, step);
        case 'action':
          return await _runAction(plan, step);
        default:
          return await _runUi(plan, step);
      }
    } catch (e) {
      return _StepOutcome(false, 'Error: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<_StepOutcome> _respond(Plan plan, PlanStep step) async {
    final gathered = plan.steps
        .where((s) => s != step && s.status == StepStatus.done && s.result.isNotEmpty)
        .map((s) => '- ${s.title}: ${_clip(s.result, 400)}')
        .join('\n');
    final context = await ctx.contextBlock(plan.goal, includeSkills: false, includeAccounts: false);
    final res = await ctx.llm.complete(
      [
        {
          'role': 'system',
          'content':
              'You are PrivateAgent finishing a task for the user. Use the information gathered by the earlier steps (and general knowledge where clearly appropriate) to write the reply. Be concise and friendly. Do not mention steps, tools or the screen agent.',
        },
        {
          'role': 'user',
          'content':
              '$context\n\nGOAL: ${plan.goal}\nWHAT TO WRITE: ${step.title}\n\nINFORMATION GATHERED:\n${gathered.isEmpty ? '(nothing)' : gathered}',
        },
      ],
      temperature: 0.5,
    );
    _tokens += res.totalTokens;
    return _StepOutcome(true, res.content);
  }

  static final RegExp _failedText = RegExp(
    r'^(error|could not|cannot|can.t|no phone number|failed|unable|api key)',
    caseSensitive: false,
  );

  Future<_StepOutcome> _runAction(Plan plan, PlanStep step) async {
    switch (step.action) {
      case 'remember':
        final fact = JsonUtils.str(step.params['fact'], step.title);
        final result = await MemoryService.instance.addFact(
          JsonUtils.str(step.params['section']),
          fact,
        );
        return switch (result) {
          MemoryAddResult.added => const _StepOutcome(true, 'Saved to memory'),
          MemoryAddResult.duplicate => const _StepOutcome(true, 'Already in memory'),
          MemoryAddResult.sensitive => const _StepOutcome(
              true,
              'Not saved: that looks like a secret. Use the Accounts vault instead.',
            ),
          MemoryAddResult.empty => const _StepOutcome(true, 'Nothing to save'),
        };
      case 'wait':
        final requested =
            step.params['seconds'] is num ? (step.params['seconds'] as num).toInt() : 2;
        final seconds = requested < 1 ? 1 : (requested > 30 ? 30 : requested);
        await Future<void>.delayed(Duration(seconds: seconds));
        return _StepOutcome(true, 'Waited $seconds s');
      default:
        final action = AgentAction(
          action: step.action,
          params: Map<String, dynamic>.from(step.params),
          response: '',
        );
        final r = step.action == 'open_app'
            ? await AppOpener.open(ctx.actions, ctx.ai, JsonUtils.str(step.params['app_name']))
            : await ctx.actions.execute(action, aiService: ctx.ai);
        final details = (r.details ?? '').trim();
        final failed = !r.success || _failedText.hasMatch(details);
        if (!failed && (step.action == 'open_app' || step.action == 'open_url')) {
          await Future<void>.delayed(const Duration(milliseconds: 2500));
        }
        return _StepOutcome(!failed, details.isEmpty ? 'Done' : _clip(details, 600));
    }
  }

  Future<_StepOutcome> _runUi(Plan plan, PlanStep step) async {
    final extra = await _uiContext(plan, step);
    final executor = TaskExecutor(
      aiService: ctx.ai,
      screenService: ctx.actions.screenAutomation,
      appLauncher: ctx.actions.appLauncher,
      shizukuService: ctx.actions.shizuku,
      onProgress: (m) {
        onProgress(m);
        // Show what the screen agent is doing right on the plan card.
        step.result = _clip(m.replaceAll('\n', ' '), 140);
        onChanged();
      },
      quiet: true,
      fastSettle: true,
      extraContext: extra,
      credentialResolver: ctx.prefs.allowCredentialFill
          ? ((String account, String field) => ctx.vault.secretFor(account, field))
          : null,
    );
    _executor = executor;
    final text = await executor.executeTask(step.title);
    _executor = null;
    _tokens += executor.tokensUsed;

    switch (executor.lastOutcome) {
      case TaskOutcome.success:
        break;
      case TaskOutcome.cancelled:
        return const _StepOutcome(false, 'Cancelled');
      case TaskOutcome.notReady:
        return _StepOutcome(false, text, fatal: true);
      default:
        return _StepOutcome(false, text);
    }

    // A replayed workflow already confirmed it ended on the recorded screen,
    // so no model call is needed to verify it.
    if (executor.usedReplay) return _StepOutcome(true, text);

    if (ctx.prefs.verifySteps && step.expected.trim().isNotEmpty && !_cancelled) {
      final verdict = await _verify(step, text);
      if (verdict != null) {
        if (step.sensitive) {
          // Never repeat a message/purchase/post just because the check was
          // unsure: keep the result but flag it.
          return _StepOutcome(true, '$text (could not confirm: $verdict)');
        }
        return _StepOutcome(false, 'Check failed: $verdict');
      }
    }
    return _StepOutcome(true, text);
  }

  /// Returns null when the screen matches the expected outcome (or the check
  /// is inconclusive), otherwise the reason it does not.
  Future<String?> _verify(PlanStep step, String report) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final screen = _clip(
        await ctx.actions.screenAutomation.getCompressedScreenDescription(step.title),
        2500,
      );
      final res = await ctx.llm.complete(
        [
          {
            'role': 'system',
            'content': 'You verify the work of a phone-automation agent. You output only compact JSON.',
          },
          {
            'role': 'user',
            'content':
                'STEP: ${step.title}\nEXPECTED: ${step.expected}\nAGENT REPORT: ${_clip(report, 300)}\n\nCURRENT SCREEN:\n$screen\n\nWas the expected outcome achieved? Answer ok=true when the screen is consistent with success, or when success cannot be judged from the screen (for example the app already returned to a list after sending). Answer ok=false only when the screen clearly shows the step did not happen.\nReturn ONLY JSON: {"ok": true, "reason": "short"}',
          },
        ],
        temperature: 0.1,
        maxTokens: 300,
        retries: 1,
      );
      _tokens += res.totalTokens;
      final json = JsonUtils.extractObject(res.content);
      if (json == null) return null;
      if (JsonUtils.boolOf(json['ok'], true)) return null;
      return JsonUtils.str(json['reason'], 'expected outcome not visible');
    } catch (_) {
      return null;
    }
  }

  Future<String> _uiContext(Plan plan, PlanStep step) async {
    final b = StringBuffer();
    b.writeln('\nCONTEXT FROM THE PLANNER:');
    b.writeln('Overall goal: ${plan.goal}');
    final done = plan.steps
        .where((s) => s.status == StepStatus.done)
        .map((s) => '- ${s.title}${s.result.isEmpty ? '' : ' → ${_clip(s.result, 120)}'}')
        .join('\n');
    if (done.isNotEmpty) b.writeln('Already done:\n$done');
    final upcoming = plan.steps
        .skip(plan.steps.indexOf(step) + 1)
        .map((s) => '- ${s.title}')
        .join('\n');
    if (upcoming.isNotEmpty) b.writeln('Later steps (handled separately, do not do them now):\n$upcoming');
    if (step.expected.isNotEmpty) b.writeln('Expected result of this sub-task: ${step.expected}');
    b.writeln(
      'IMPORTANT: the screen may already be further along than this sub-task expects. At your very first look, if the expected result is already visible, or the screen already shows the result of a later step, answer immediately with action "done" and is_complete true. Never repeat or undo work that is already on screen.',
    );
    final hint = _hints[step.id];
    if (hint != null && hint.isNotEmpty) {
      b.writeln(
        'A previous attempt at this sub-task failed: ${_clip(hint, 250)}. Take a different approach.',
      );
    }
    final mem = await ctx.memory.promptContext(maxChars: 1200);
    if (mem.isNotEmpty) b.writeln('Facts about the user (use only if needed):\n$mem');
    if (ctx.prefs.customInstructions.trim().isNotEmpty) {
      b.writeln('User instructions: ${ctx.prefs.customInstructions.trim()}');
    }
    final skill = ctx.skills.promptFor('${step.title} ${plan.goal}');
    if (skill.isNotEmpty) b.writeln('Relevant skill:\n$skill');
    b.writeln(
      'If the sub-task asks you to find, read or check information, put that information itself in the "reasoning" of your final done/is_complete response.',
    );
    if (ctx.prefs.allowCredentialFill) {
      final accounts = ctx.vault.promptSummary();
      if (accounts.isNotEmpty) {
        b.writeln(
          'Saved accounts (labels): \n$accounts\nTo log in, click the field first, then use the action type_credential: {"account": "<label>", "field": "username" or "password"}. Never type passwords with type_text and never write them in reasoning.',
        );
      }
    }
    return b.toString();
  }

  /// Returns the index of the first step whose outcome is not yet visible on
  /// screen (>= [index]). One short model call, only used after a failure.
  Future<int> _reconcile(Plan plan, int index) async {
    try {
      final screen = _clip(await _screenSnapshot(plan.goal), 2200);
      if (screen.isEmpty) return index;
      final remaining = <String>[];
      for (var k = index; k < plan.steps.length; k++) {
        final s = plan.steps[k];
        remaining.add(
          '${k - index + 1}. ${s.title}${s.expected.isEmpty ? '' : ' (result: ${s.expected})'}',
        );
      }
      final res = await ctx.llm.complete(
        [
          {
            'role': 'system',
            'content': 'You judge progress of a phone-automation plan from the current screen. You output only compact JSON.',
          },
          {
            'role': 'user',
            'content':
                'GOAL: ${plan.goal}\n\nREMAINING STEPS, in order:\n${remaining.join('\n')}\n\nCURRENT SCREEN:\n$screen\n\nHow many of these steps, counting in order from step 1, are already done judging by the screen? A step counts as done when its result is visible, or when the screen clearly shows later progress that requires it. Use 0 if step 1 is clearly not done.\nReturn ONLY JSON: {"achieved": 0}',
          },
        ],
        temperature: 0.0,
        maxTokens: 120,
        retries: 0,
      );
      _tokens += res.totalTokens;
      final json = JsonUtils.extractObject(res.content);
      final n = json != null && json['achieved'] is num ? (json['achieved'] as num).toInt() : 0;
      if (n <= 0) return index;
      return index + (n > remaining.length ? remaining.length : n);
    } catch (_) {
      return index;
    }
  }

  Future<String> _screenSnapshot(String goal) async {
    try {
      return await ctx.actions.screenAutomation.getCompressedScreenDescription(goal);
    } catch (_) {
      return '';
    }
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
}
