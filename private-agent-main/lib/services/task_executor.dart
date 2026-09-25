import '../agent/safe_cast.dart';
import '../lab/lab_vision.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'skill_memory_service.dart';
import 'recovery_engine.dart';
import '../models/saved_skill.dart';
import '../agent/workflow.dart';

/// How the last [TaskExecutor.executeTask] call ended.
enum TaskOutcome { none, success, failed, cancelled, notReady }

/// Executes multi-step UI automation tasks using LLM-guided screen reading.
///
/// Flow: User gives high-level goal → LLM reads screen → decides next action →
/// executes → reads screen again → repeats until goal is complete.
class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;
  final NotificationService _notificationService = NotificationService();
  final SkillMemoryService _skillMemory = SkillMemoryService();
  final RecoveryEngine _recoveryEngine = RecoveryEngine();

  /// Callback to report progress messages to the UI
  final void Function(String message)? onProgress;

  // ── Additions used by the planner/orchestrator layer. All of them default
  // ── to the original behaviour, so existing callers are unaffected.

  /// When true the executor stays silent: no toasts, no notifications, no
  /// history entry and no end-of-task pauses (the caller reports instead).
  final bool quiet;

  /// When true the fixed waits between steps are replaced by a wait that ends
  /// as soon as the screen has stopped changing (never longer than the
  /// original delay), which makes runs noticeably faster.
  final bool fastSettle;

  /// Extra guidance appended to the system prompt (memory, hints, accounts).
  final String extraContext;

  /// Resolves a saved credential (account label + field) to its secret. The
  /// secret is typed locally and never sent to the language model.
  final Future<String?> Function(String account, String field)?
      credentialResolver;

  /// Set by every [executeTask] call.
  TaskOutcome lastOutcome = TaskOutcome.none;

  /// Tokens consumed by the last [executeTask] call.
  int tokensUsed = 0;

  /// True when the last call was completed by instantly replaying a learned
  /// workflow (no model calls for navigation).
  bool usedReplay = false;

  String _goal = '';

  /// Set to true to cancel the running task
  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
    this.quiet = false,
    this.fastSettle = false,
    this.extraContext = '',
    this.credentialResolver,
  }) : _aiService = aiService,
       _screenService = screenService,
       _appLauncher = appLauncher,
       _shizukuService = shizukuService;

  /// Cancel the currently running task — takes effect immediately
  void cancel() {
    _cancelled = true;
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  static const String _taskSystemPrompt = '''
You are a phone automation agent. You are given a TASK and the current SCREEN content.
You must decide what single action to take next to accomplish the task.

Respond with ONLY a JSON object (no markdown, no code fences):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "why you chose this action",
  "is_complete": false
}

Available actions:
- click_text: {"text": "exact text to click"} - Click an element by its visible text
- click_at: {"x": 540, "y": 960} - Click at screen coordinates (use bounds from screen dump)
- type_text: {"text": "hello", "field_hint": "optional hint"} - Type into the focused/first edit field
- press_enter: {} - Press the Enter/Search key on the keyboard to submit a search/form
- scroll: {"direction": "down"} - Scroll down/up on the current view
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500} - Swipe from start to end coordinates (e.g. open app drawer, navigate carousels)
- press_back: {} - Press the back button
- press_home: {} - Press the home button
- open_app: {"app_name": "WhatsApp"} - Open an app
- wait: {} - Wait a moment for content to load
- done: {} - Task is complete

Rules:
- You will receive a TEXT DUMP of the accessibility tree containing exact text strings and center coordinates.
- ALWAYS use the text dump to decide your next action.
- If you need to click something, prefer using `click_text`. If the element does not have text, use `click_at` with the coordinates provided in the text dump.
- When the TASK asks you to write or send something WRITTEN (a message, reply, caption, summary, explanation, description, review...) rather than just search for or navigate to something, the `text` you put in type_text must be that actual finished writing — real sentences that fulfil the request — not the topic words from the task copied verbatim. For example, if the task is "send mom information about how AI is useful", typing "how AI is useful" is wrong: compose a few real, informative sentences about how AI is useful and type those. Write the whole thing in one type_text step before submitting/sending it.
- When typing in a search box (as opposed to composing a message), type the short search terms as usual — this rule is only about fields meant to hold real written content.
- When typing in a search box, you MUST click it first, wait a step, and THEN type.
- After typing a search query, use `press_enter` once. If the screen does not change, click the exact visible suggestion text. Do not repeat the same submit action more than twice.
- Never scroll or swipe more than three times in a row. After three scrolls, choose the best visible result or take a different action instead of continuing to browse indefinitely.
- Set is_complete=true ONLY when the task is fully done.
- If you need to find something by scrolling, scroll and then check the screen again.
- If you need to open an app (like Wikipedia, Spotify, etc.) and you cannot find it after a couple of scrolls, ASSUME it is not installed. Immediately open Chrome or Google to search for the info on the web instead.
- If stuck after 3 attempts, set is_complete=true and explain in reasoning.
- Keep reasoning very brief (1 sentence)
''';

  String get _systemPrompt {
    final base = extraContext.trim().isEmpty
        ? _taskSystemPrompt
        : '$_taskSystemPrompt\n$extraContext';
    return base;
  }

  /// Extract JSON safely even if wrapped in markdown or conversational text
  String _extractJson(String text) {
    // 1. Try to find a markdown json code block
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }

    // 2. Fallback: find the first { and the last }
    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }

    return text.trim();
  }

  /// Execute a multi-step task with LLM guidance
  Future<String> executeTask(String userGoal) async {
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] executeTask() CALLED with goal: $userGoal",
    );
    _cancelled = false;
    lastOutcome = TaskOutcome.failed;
    tokensUsed = 0;
    usedReplay = false;
    _goal = userGoal;

    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Checking if accessibility service is running...",
    );
    final isRunning = await _screenService.isServiceRunning();
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Accessibility service isRunning = $isRunning",
    );
    if (!isRunning) {
      await ScreenAutomationService.logToNative(
        "[TaskExecutor] Accessibility service not running, returning early.",
      );
      lastOutcome = TaskOutcome.notReady;
      return 'Accessibility service is not enabled. Go to Settings \u2192 Accessibility \u2192 PrivateAgent Screen Control and enable it.';
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');
    _report('Starting task: $userGoal');

    // Check skill memory first
    final skillMatch = await _skillMemory.matchSkill(userGoal);
    final savedSkill = skillMatch?.skill;
    final slotValue = skillMatch?.value;
    if (savedSkill != null && savedSkill.isReliable &&
        _canReplay(savedSkill, userGoal, templated: slotValue != null)) {
      _report(
        'Found a learned workflow! Replaying ${savedSkill.steps.length} steps...',
      );
      final replayWatch = Stopwatch()..start();
      final replaySuccess = await _replaySkill(savedSkill, results, value: slotValue);
      replayWatch.stop();
      if (replaySuccess) {
        usedReplay = true;
        await _skillMemory.recordReplay(savedSkill.id, replayWatch.elapsedMilliseconds);
        var answer = 'Done.';
        if (_wantsInformation(userGoal)) {
          answer = (await _answerFromScreen(userGoal)) ?? 'Done.';
        }
        results.add('Task complete via skill memory.');
        _report('Task complete (via skill memory).');
        await _notify(
          'Task Completed',
          'Agent finished its goal using memory.',
        );
        await _logHistory(
          userGoal,
          'Success',
          0,
          savedSkill.steps.length,
          results,
        );
        await _toast('Task Complete! (Memory)');
        lastOutcome = TaskOutcome.success;
        return answer;
      } else {
        if (_cancelled) {
          lastOutcome = TaskOutcome.cancelled;
          return 'Task cancelled.';
        }
        _report('Replay failed, falling back to AI...');
        await _skillMemory.recordFailure(savedSkill.id);
        // Start the AI from a clean state so that what it records is a full,
        // replayable workflow rather than the tail of a half-finished one.
        await _screenService.pressHome();
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }

    // Smart pre-launch shortcuts: execute common sequences without LLM
    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    String previousScreenContent = '';
    int consecutiveStalls = 0;
    int verifyBounces = 0;
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';
    int labRescues = 0;
    int consecutiveScrolls = 0;
    int totalTokens = 0;
    final List<ActionStep> executedSteps = [];

    if (shortcut != null && shortcut.isNotEmpty) {
      results.add('Using navigation shortcut: ${shortcut.length} steps');
      _report('Using navigation shortcut...');
      for (final step in shortcut) {
        if (_cancelled) break;

        bool success = false;
        if (step.action == 'open_app') {
          final appName = step.params['app_name'] as String? ?? '';
          final res = await _appLauncher.openApp(appName);
          success = res.startsWith('Opened');
          await Future.delayed(const Duration(milliseconds: 3000));
        } else if (step.action == 'click_text') {
          final text = step.params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          await Future.delayed(const Duration(milliseconds: 1500));
        }

        if (success) {
          executedSteps.add(step);
          lastAction = step.action;
        } else {
          break; // Fall back to AI if shortcut step fails
        }
      }
    } else {
      // If no shortcut is used, and we are currently inside the PrivateAgent app,
      // press Home so the AI doesn't see its own chat bubbles and get confused by the task text.
      final currentPkg = await _screenService.getCurrentPackage();
      if (currentPkg == 'com.orailnoor.privateagent') {
        _report('Moving to background...');
        await _screenService.pressHome();
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }

    for (int step = 0; step < _aiService.maxSteps; step++) {
      // Check for cancellation
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notify(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await _logHistory(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _toast('Task Cancelled');
        lastOutcome = TaskOutcome.cancelled;
        return 'Task cancelled.';
      }

      // Adaptive delay: give Android apps time to transition screens, load data, or open keyboards
      int delay = 1200; // Default 1.2s delay for most actions
      if (lastAction == 'open_app') {
        delay = 3000; // Apps need ~3 seconds to fully cold-start and render
      } else if (lastAction == 'type_text') {
        delay =
            2000; // Typing involves keyboards and often triggers heavy network requests (search)
      } else if (lastAction == 'click_text' || lastAction == 'click_at') {
        delay = 1500; // Clicking usually triggers a screen transition
      } else if (lastAction == 'scroll') {
        delay = 1000; // Scrolling is relatively fast
      }
      if (fastSettle) {
        await _waitForSettle(maxMs: delay, lastAction: lastAction);
      } else {
        await Future.delayed(Duration(milliseconds: delay));
      }

      // 1. Read the current screen text
      final screenContent = _aiService.useScreenCompression
          ? await _screenService.getCompressedScreenDescription(userGoal)
          : await _screenService.getScreenDescription();
      developer.log(
        '=== SCREEN DUMP (Step ${step + 1}) ===\n$screenContent',
        name: 'PrivateAgent',
      );

      // Detect a "silent failure": the native action reported success but the
      // screen looks exactly like it did before the action, for an action type
      // that should visibly change something. The model already gets a fresh
      // screen dump every step, so surfacing this costs no extra round trip —
      // it just tells the model its last move didn't actually do anything.
      const changeActions = {
        'click_text', 'click_at', 'type_text', 'press_enter', 'swipe', 'press_back',
      };
      String stallHint = '';
      if (step > 0 &&
          changeActions.contains(lastAction) &&
          screenContent.trim() == previousScreenContent.trim()) {
        consecutiveStalls++;
        stallHint =
            '\n\nNOTE: Your previous action ($lastAction) did not visibly change anything on screen — it may have missed its target, or nothing happened. Do not repeat it; look again and try a different element or approach.';
      } else {
        consecutiveStalls = 0;
      }
      previousScreenContent = screenContent;

      // Determine previous result string
      final prevResultStr = step > 0 && results.isNotEmpty
          ? '\nPREVIOUS ACTION RESULT: ${results.last}\n'
          : '';

      // Build failure hint if agent is stuck in a loop
      String failureHint = '';
      if (consecutiveFailures >= 3) {
        failureHint =
            '\n\nWARNING: You have failed $consecutiveFailures times in a row with the same approach. You MUST try a completely different action. If open_app failed, try press_home and look for the app icon on the home screen instead. If click_text failed, use click_at with coordinates. Do NOT repeat the same failed action.';
      }

      // 2. Build the prompt (system prompt is sent separately via sendTaskMessage)
      final prompt =
          '''TASK: $userGoal

CURRENT SCREEN TEXT DUMP:
$screenContent$prevResultStr$failureHint$stallHint
Step ${step + 1}/${_aiService.maxSteps}. Look at the text dump and coordinates. What is the next action?''';

      developer.log('=== AI PROMPT ===\n$prompt', name: 'PrivateAgent');

      // 3. Get AI response — races against cancel signal so Stop works immediately
      String response;
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(_systemPrompt, prompt);

        // Race: whichever finishes first wins
        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);

        if (result == null || _cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notify(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await _logHistory(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _toast('Task Cancelled');
        lastOutcome = TaskOutcome.cancelled;
        return 'Task cancelled.';
        }

        final aiResponse = result as AiResponse;
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;
        tokensUsed = totalTokens;

        developer.log(
          '=== RAW AI RESPONSE ===\n$response',
          name: 'PrivateAgent',
        );
      } catch (e) {
        if (_cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notify(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await _logHistory(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _toast('Task Cancelled');
          await _pause(2);
        lastOutcome = TaskOutcome.cancelled;
        return 'Task cancelled.';
        }
        results.add('AI error: $e');
        _report('Error: $e');
        await _notify(
          'Task Error',
          'AI encountered an error.',
        );
        await _logHistory(
          userGoal,
          'Failed',
          totalTokens,
          step,
          results,
        );
        await _toast('AI Error: $e');
        await _pause(3);
        lastOutcome = TaskOutcome.failed;
        return 'I could not complete the task because the AI service failed.';
      }

      // Check for cancellation after AI response
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notify(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await _logHistory(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _toast('Task Cancelled');
        await _pause(2);
        lastOutcome = TaskOutcome.cancelled;
        return 'Task cancelled.';
      }

      // 4. Parse the action (with one retry on failure)
      Map<String, dynamic>? actionJson;
      String? parsedJsonStr;
      try {
        String jsonStr = _extractJson(response);

        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
        parsedJsonStr = jsonStr;
      } catch (firstError) {
        // First attempt failed — retry once
        developer.log(
          '=== JSON PARSE FAILED, RETRYING ===\nError: $firstError\nRaw: $response',
          name: 'PrivateAgent',
        );
        _report('Retrying step ${step + 1}...\n(Failed to parse: $firstError)');
        // Wait 2 seconds before retrying to prevent rate-limit spam
        await Future.delayed(const Duration(seconds: 2));
        try {
          final retryResponse = await _aiService.sendTaskMessage(
            _systemPrompt,
            prompt,
          );
          totalTokens += retryResponse.totalTokens;
          tokensUsed = totalTokens;
          developer.log(
            '=== RETRY AI RESPONSE ===\n${retryResponse.content}',
            name: 'PrivateAgent',
          );

          String jsonStr = _extractJson(retryResponse.content);
          actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
          parsedJsonStr = jsonStr;
        } catch (e) {
          results.add('Step ${step + 1}: Error after retry: $e');

          String debugInfo = 'Error: $e';
          _report('AI Error: $debugInfo\n\nRaw output:\n${response}');

          await _notify(
            'Task Error',
            'AI formatting error.',
          );
          await _logHistory(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _toast('Agent Error: $e');
          await _pause(3);
          lastOutcome = TaskOutcome.failed;
          return 'I could not understand the AI response. Please try again.';
        }
      }

      final action = actionJson['action'] as String? ?? 'done';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      var isComplete = actionJson['is_complete'] == true;

      if (consecutiveStalls >= 2 && labRescues < 3) {
        labRescues++;
        final acted = await LabVision.instance.rescue(
          goal: userGoal,
          failedAction: '$lastAction (ran, but nothing visibly changed, twice in a row)',
          screen: _screenService,
          ai: _aiService,
          report: (m) => _report(m),
        );
        if (acted) {
          consecutiveStalls = 0;
          results.add('Used the vision model — repeated actions were having no visible effect.');
          lastAction = 'vision_rescue';
          continue;
        }
      }

      developer.log(
        '=== PARSED ACTION ===\nAction: $action\nParams: $params\nReasoning: $reasoning\nIs Complete: $isComplete',
        name: 'PrivateAgent',
      );

      _report('Step ${step + 1}: $reasoning');

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;
      final repeatLimit = action == 'press_enter'
          ? 2
          : (action == 'scroll' || action == 'swipe' ? 3 : 1000);
      if (sameActionCount > repeatLimit) {
        final blockedResult =
            'Blocked repeated $action action. Use a different action on the visible screen.';
        results.add(blockedResult);
        _report(blockedResult);
        consecutiveFailures = 3;
        lastFailedAction = action;
        lastAction = action;
        continue;
      }
      lastAction = action; // Track for adaptive delay

      // 5. Execute the action
      bool success = false;
      String actionResult = '';

      // Remember the screen this action is performed on (exact-replay data).
      // (the screen the model just looked at, so no extra screen read).
      final ScreenSnap? preSnap = (action == 'done' || action == 'wait')
          ? null
          : ScreenSnap(_screenService.lastPackage, _screenService.lastNodes);

      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;

        case 'click_at':
          final x = asDouble(params['x']) ?? 0;
          final y = asDouble(params['y']) ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;

        case 'type_text':
          final text = params['text'] as String? ?? '';
          final hint = params['field_hint'] as String?;
          success = await _screenService.typeText(text, fieldHint: hint);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;

        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;

        case 'type_credential':
          final credError = await _typeCredentialAction(params);
          success = credError == null;
          actionResult = credError ?? 'Typed the saved credential';
          break;

        case 'swipe':
          final startX = asDouble(params['startX']) ?? 540;
          final startY = asDouble(params['startY']) ?? 2000;
          final endX = asDouble(params['endX']) ?? 540;
          final endY = asDouble(params['endY']) ?? 500;

          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;

        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
          // Prefer a look from the vision model over blind scrolling once
          // scrolling alone hasn't found the target — scrolling is a guess,
          // the vision model can usually just point straight at what's needed.
          if (consecutiveScrolls >= 1 && labRescues < 3) {
            labRescues++;
            final acted = await LabVision.instance.rescue(
              goal: userGoal,
              failedAction: 'scroll $direction (repeated, not finding the target)',
              screen: _screenService,
              ai: _aiService,
              report: (m) => _report(m),
            );
            if (acted) {
              consecutiveScrolls = 0;
              consecutiveFailures = 0;
              success = true;
              actionResult = 'Used the vision model instead of scrolling further';
              break;
            }
          }
          consecutiveScrolls++;
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
          break;

        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = 'Pressed back';
          break;

        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = 'Pressed home';
          break;

        case 'open_app':
          final appName = params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;

        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;

        case 'done':
          results.add('Task complete: $reasoning');
          _report('Task complete: $reasoning');
          await _notify(
            'Task Completed',
            reasoning.trim().isEmpty ? 'Agent finished its goal.' : reasoning,
          );
          await _toast('Task completed');
          await _learnWorkflow(userGoal, executedSteps, settle: false);
          lastOutcome = TaskOutcome.success;
          return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();

        default:
          actionResult = 'Unknown action: $action';
      }

      developer.log(
        '=== NATIVE EXECUTION RESULT ===\n$actionResult',
        name: 'PrivateAgent',
      );

      // Track consecutive failures to detect stuck loops
      if (!success) {
        if (action == lastFailedAction) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;
          lastFailedAction = action;
        }

        if (action != 'scroll') consecutiveScrolls = 0;

        // Experimental: vision-model rescue when stuck (no-op unless enabled).
        if (consecutiveFailures >= 3 && labRescues < 3) {
          labRescues++;
          final acted = await LabVision.instance.rescue(
            goal: userGoal,
            failedAction: lastFailedAction,
            screen: _screenService,
            ai: _aiService,
            report: (m) => _report(m),
          );
          if (acted) {
            consecutiveFailures = 0;
            continue;
          }
        }

        // If stuck for 5+ consecutive failures, give up on this task
        if (consecutiveFailures >= 5) {
          results.add(
            'Agent is stuck. Stopping task after $consecutiveFailures consecutive failures.',
          );
          _report('Agent stuck — stopping task.');
          await _notify(
            'Task Stuck',
            'Agent could not complete the task after repeated failures.',
          );
          await _logHistory(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _toast('Agent stuck. Task stopped.');
          await _pause(4);
          lastOutcome = TaskOutcome.failed;
          return 'I could not complete the task. Please try again.';
        }

        final recovery = await _recoveryEngine.diagnose(action, screenContent);
        _report('Recovering: ${recovery.description}');

        if (recovery.action == 'wait') {
          await Future.delayed(const Duration(seconds: 2));
        } else if (recovery.action == 'press_back') {
          await _screenService.pressBack();
        } else if (recovery.action == 'scroll') {
          final dir = recovery.params['direction'] ?? 'down';
          if (dir == 'down') {
            await _shizukuService.runCommand(
              'input swipe 540 1800 540 600 600',
            );
          } else {
            await _shizukuService.runCommand(
              'input swipe 540 600 540 1800 600',
            );
          }
        } else if (recovery.action == 'press_home') {
          await _screenService.pressHome();
        }

        results.add('Recovery step: ${recovery.description}');
        continue;
      } else {
        consecutiveFailures = 0;
        lastFailedAction = '';
        executedSteps.add(
          ActionStep(
            action: action,
            params: Map<String, dynamic>.from(params),
            meta: WorkflowKit.stepMeta(action, params, preSnap),
          ),
        );
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      // Provide progress feedback
      if (!isComplete && (step + 1) % 3 == 0) {
        await _toast('Working... (Step ${step + 1})');
      }

      if (isComplete) {
        // Verify once before trusting the model's own "done" claim: settle,
        // re-read the screen post-action, and ask a short, separate check
        // against the actual goal — this is what used to catch a task that
        // only *looked* finished. Bounded to 2 bounces so a wrong verdict
        // can't loop forever, and skipped entirely if verification itself
        // errors, so it never blocks a real completion.
        if (verifyBounces < 2) {
          await Future.delayed(const Duration(milliseconds: 900));
          try {
            final postScreen = _aiService.useScreenCompression
                ? await _screenService.getCompressedScreenDescription(userGoal)
                : await _screenService.getScreenDescription();
            final vr = await _aiService.sendTaskMessage(
              'You check whether a phone-automation task actually finished. Reply with ONLY JSON: {"achieved": true or false, "reason": "one short sentence"}. Be strict — only true if the screen clearly shows the task is done.',
              'TASK: $userGoal\n\nCURRENT SCREEN:\n$postScreen\n\nHas the task been achieved?',
            );
            totalTokens += vr.totalTokens;
            tokensUsed = totalTokens;
            final vj = jsonDecode(_extractJson(vr.content)) as Map<String, dynamic>;
            if (vj['achieved'] != true) {
              verifyBounces++;
              final reason = '${vj['reason'] ?? ''}'.trim();
              results.add('Verification: not yet complete${reason.isEmpty ? '' : ' — $reason'}.');
              _report(reason.isEmpty ? 'Double-checking…' : 'Not quite there yet: $reason');
              previousScreenContent = '';
              continue;
            }
          } catch (_) {
            // Verification failed to run — trust the model's own claim rather than stall.
          }
        }

        results.add('Task complete.');
        _report('Task complete.');
        await _notify(
          'Task Completed',
          'Agent finished its goal.',
        );
        await _logHistory(
          userGoal,
          'Success',
          totalTokens,
          step,
          results,
        );

        // Learn the exact workflow from this single successful run
        await _learnWorkflow(userGoal, executedSteps, settle: true);

        await _toast('Task Complete!');
        // Wait 4 seconds so the user can see the result before jumping back
        await _pause(4);
          lastOutcome = TaskOutcome.success;
          return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
      }
    }

    results.add(
      'Reached maximum steps (${_aiService.maxSteps}). Task may be incomplete.',
    );
    _report('Reached maximum steps.');
    await _notify(
      'Task Stopped',
      'Reached maximum steps (${_aiService.maxSteps}).',
    );
    await _logHistory(
      userGoal,
      'Failed',
      totalTokens,
      _aiService.maxSteps,
      results,
    );
    await _toast('Reached maximum steps.');
    await _pause(4);

    lastOutcome = TaskOutcome.failed;
    return 'I could not complete the task within the allowed steps.';
  }

  void _report(String message) {
    onProgress?.call(message);
  }

  Future<void> _notify(String title, String body) async {
    if (quiet) return;
    await _notificationService.showTaskCompleteNotification(title, body);
  }

  Future<void> _toast(String message) async {
    if (quiet) return;
    await _screenService.showToast(message);
  }

  Future<void> _logHistory(
    String goal,
    String status,
    int tokens,
    int steps,
    List<String> trace,
  ) async {
    if (quiet) return;
    await TaskHistoryLogger.logTask(goal, status, tokens, steps, trace);
  }

  Future<void> _pause(int seconds) async {
    if (quiet) return;
    await Future.delayed(Duration(seconds: seconds));
  }

  /// Types a saved credential into the focused field. Returns null on success
  /// or a short error message. The secret itself is never logged or reported.
  Future<String?> _typeCredentialAction(Map<String, dynamic> params) async {
    final account = params['account'] as String? ?? '';
    final field = params['field'] as String? ?? 'password';
    final resolver = credentialResolver;
    if (resolver == null) return 'Saved credentials are disabled';
    final secret = await resolver(account, field);
    if (secret == null || secret.isEmpty) {
      return 'No saved $field for "$account"';
    }
    final typed = await _screenService.typeText(
      secret,
      fieldHint: params['field_hint'] as String?,
    );
    return typed ? null : 'Could not type into the field';
  }

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) return true;

    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;

    final result = await _shizukuService.runCommand('input keyevent 66');
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) return true;

    final isDown = direction.toLowerCase() == 'down';
    return _performSwipe(540, isDown ? 1800 : 600, 540, isDown ? 600 : 1800);
  }

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;

    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;

    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} '
      '${endX.toInt()} ${endY.toInt()} 600',
    );
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  /// Replays a saved skill without using the LLM
  // ─── Exact workflow learning & instant replay ─────────────────────────

  /// Waits until the screen stops changing after an action. It ends early once
  /// the screen has changed (or half the maximum wait has passed) and then
  /// stayed the same for two consecutive reads.
  Future<void> _waitForSettle({required int maxMs, required String lastAction}) async {
    if (lastAction.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 150));
      return;
    }
    final minMs = lastAction == 'open_app' ? 1200 : (lastAction == 'scroll' ? 350 : 450);
    final before = WorkflowKit.labels(_screenService.lastNodes, max: 40).join('|');
    final watch = Stopwatch()..start();
    var previous = '';
    var stable = 0;
    await Future.delayed(const Duration(milliseconds: 200));
    while (watch.elapsedMilliseconds < maxMs) {
      if (_cancelled) return;
      final nodes = await _screenService.dumpScreen();
      final sig = WorkflowKit.labels(nodes, max: 40).join('|');
      stable = (sig.isNotEmpty && sig == previous) ? stable + 1 : 0;
      previous = sig;
      final changed = sig != before;
      if (stable >= 2 &&
          watch.elapsedMilliseconds >= minMs &&
          (changed || watch.elapsedMilliseconds >= maxMs ~/ 2)) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<ScreenSnap?> _snapshot() async {
    try {
      final pkg = await _screenService.getCurrentPackage() ?? '';
      final nodes = await _screenService.dumpScreen();
      return ScreenSnap(pkg, nodes);
    } catch (_) {
      return null;
    }
  }

  /// Stores the executed steps (with their exact targets and screen
  /// signatures) so the same task can be replayed without any model call.
  Future<void> _learnWorkflow(
    String goal,
    List<ActionStep> steps, {
    required bool settle,
  }) async {
    try {
      if (steps.isEmpty) return;
      if (settle) await Future.delayed(const Duration(milliseconds: 600));
      final end = await _snapshot();
      await _skillMemory.saveSkill(
        goal,
        WorkflowKit.compact(steps),
        finalPkg: end?.pkg ?? '',
        finalSig: end == null ? const <String>[] : WorkflowKit.labels(end.nodes),
      );
    } catch (_) {}
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final RegExp _dynamicWords = RegExp(
    r'\b(latest|last|newest|unread|recent|current|currently|now|today|tonight|tomorrow|reply|respond|summarize|summarise)\b',
  );

  static final RegExp _infoWords = RegExp(
    r'\b(what|which|who|whom|when|where|how many|how much|read|tell me|check|find out|show me|list|count|status|latest|unread|any new|is there|are there)\b',
  );

  bool _wantsInformation(String goal) => _infoWords.hasMatch(goal.toLowerCase());

  /// A replay repeats literal taps and typed text, so only replay when that is
  /// what the current goal asks for.
  bool _canReplay(SavedSkill skill, String goal, {bool templated = false}) {
    final g = _norm(goal);
    final exact = _norm(skill.task) == g;
    for (final step in skill.steps) {
      if (step.action != 'type_text') continue;
      final typed = _norm((step.params['text'] ?? '').toString());
      if (typed.isEmpty || g.contains(typed)) continue;
      if (templated && typed == _norm(skill.slotExample)) continue;
      // Text the model composed itself: repeat it only for the very same,
      // non-contextual request.
      if (!exact || _dynamicWords.hasMatch(g)) return false;
    }
    return true;
  }

  Future<String?> _answerFromScreen(String goal) async {
    try {
      final screen = await _screenService.getCompressedScreenDescription(goal);
      final res = await _aiService.sendTaskMessage(
        'You answer questions about what is on an Android phone screen. Use only the screen text provided. Be concise: one to three sentences.',
        'TASK: $goal\n\nSCREEN:\n$screen\n\nAnswer the task.',
      );
      tokensUsed += res.totalTokens;
      final text = res.content.trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Waits until the foreground app is [pkg] and the screen shows at least
  /// [minCoverage] of the recorded [sig] labels. Returns the matching snapshot.
  Future<ScreenSnap?> _waitForScreen(
    String pkg,
    List<String> sig, {
    int timeoutMs = 9000,
    double minCoverage = 0.6,
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < timeoutMs) {
      if (_cancelled) return null;
      final snap = await _snapshot();
      if (snap != null &&
          (pkg.isEmpty || snap.pkg == pkg) &&
          WorkflowKit.matches(sig, WorkflowKit.labels(snap.nodes), minCoverage: minCoverage)) {
        return snap;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _waitForPackage(String pkg, {int timeoutMs = 8000}) async {
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < timeoutMs) {
      if (_cancelled) return false;
      if (await _screenService.getCurrentPackage() == pkg) return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Taps the element a click step recorded: found live by label (nearest to
  /// where it was), otherwise by text, otherwise at the recorded coordinates.
  Future<bool> _replayClick(ActionStep step, ScreenSnap? snap) async {
    final meta = step.meta;
    final recText = (meta['tx'] ?? '').toString();
    final recDesc = (meta['td'] ?? '').toString();
    final label = recText.isNotEmpty
        ? recText
        : (recDesc.isNotEmpty ? recDesc : (step.params['text'] ?? '').toString());
    final recX = asDouble(meta['cx']);
    final recY = asDouble(meta['cy']);

    // The element may still be loading: look for it for up to ~2.5 seconds.
    var live = snap;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (live != null && label.isNotEmpty) {
        final node = WorkflowKit.findByLabel(
          live.nodes,
          label,
          cx: recX ?? 0,
          cy: recY ?? 0,
          cls: (meta['tc'] ?? '').toString(),
        );
        if (node != null) {
          return _screenService.clickAt(WorkflowKit.centerX(node), WorkflowKit.centerY(node));
        }
      }
      if (label.isEmpty || attempt == 9) break;
      await Future.delayed(const Duration(milliseconds: 250));
      live = await _snapshot();
    }

    if (step.action == 'click_text') {
      final text = (step.params['text'] ?? '').toString();
      if (text.isNotEmpty && await _screenService.clickByText(text)) return true;
    }
    if (recX != null && recY != null) {
      return _screenService.clickAt(recX, recY);
    }
    final x = asDouble(step.params['x']);
    final y = asDouble(step.params['y']);
    if (x != null && y != null) return _screenService.clickAt(x, y);
    return false;
  }

  Future<bool> _replaySkill(
    SavedSkill skill,
    List<String> results, {
    String? value,
  }) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) return false;

      final step = skill.steps[i];
      final meta = step.meta;
      final exact = meta.isNotEmpty;
      final pkg = (meta['pkg'] ?? '').toString();
      final sig = WorkflowKit.stringList(meta['sig']);
      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');

      ScreenSnap? snap;
      if (exact && step.action != 'open_app') {
        // Continue the moment the screen looks like it did when recorded.
        snap = await _waitForScreen(pkg, sig);
        if (snap == null) {
          results.add('Replay stopped at step ${i + 1}: screen is not as recorded');
          return false;
        }
      } else if (!exact) {
        // Workflow saved by an older version: fixed delays.
        int delay = 1200;
        if (step.action == 'open_app') {
          delay = 3000;
        } else if (step.action == 'type_text') {
          delay = 2000;
        } else if (step.action == 'click_text' || step.action == 'click_at') {
          delay = 1500;
        } else if (step.action == 'scroll') {
          delay = 1000;
        }
        await Future.delayed(Duration(milliseconds: delay));
      }

      bool success = false;
      String actionResult = '';

      switch (step.action) {
        case 'click_text':
        case 'click_at':
          success = await _replayClick(step, snap);
          actionResult = success ? 'Tapped the recorded target' : 'Could not tap the recorded target';
          break;
        case 'type_text':
          var text = step.params['text'] as String? ?? '';
          // A learned template: type the new value where the example was typed.
          if (value != null && skill.isTemplate && _norm(text) == _norm(skill.slotExample)) {
            text = value;
          }
          final hint = step.params['field_hint'] as String?;
          success = await _screenService.typeText(text, fieldHint: hint);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;
        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;
        case 'type_credential':
          final credError = await _typeCredentialAction(step.params);
          success = credError == null;
          actionResult = credError ?? 'Typed the saved credential';
          break;
        case 'swipe':
          final startX = asDouble(step.params['startX']) ?? 540;
          final startY = asDouble(step.params['startY']) ?? 2000;
          final endX = asDouble(step.params['endX']) ?? 540;
          final endY = asDouble(step.params['endY']) ?? 500;
          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;
        case 'scroll':
          final direction = step.params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
          break;
        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = 'Pressed back';
          break;
        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = 'Pressed home';
          break;
        case 'open_app':
          final appName = step.params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;
        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;
        case 'done':
          success = true;
          actionResult = 'Done step reached';
          break;
        default:
          success = false;
          actionResult = 'Unknown action: ${step.action}';
      }

      results.add('Memory Replay Step ${i + 1}: $actionResult');
      developer.log(
        '=== MEMORY REPLAY RESULT ===\n$actionResult',
        name: 'PrivateAgent',
      );

      if (!success) {
        return false; // Break out of replay if a step fails
      }

      // Give the UI a moment to react before looking at it again.
      if (step.action == 'open_app') {
        final nextPkg = i + 1 < skill.steps.length
            ? (skill.steps[i + 1].meta['pkg'] ?? '').toString()
            : skill.finalPkg;
        if (nextPkg.isNotEmpty) {
          await _waitForPackage(nextPkg);
          await Future.delayed(const Duration(milliseconds: 400));
        } else {
          await Future.delayed(const Duration(milliseconds: 3000));
        }
      } else if (step.action == 'type_text') {
        await Future.delayed(const Duration(milliseconds: 500));
      } else if (step.action == 'scroll' || step.action == 'swipe') {
        await Future.delayed(const Duration(milliseconds: 650));
      } else {
        await Future.delayed(const Duration(milliseconds: 350));
      }
    }

    // Confirm the workflow ended where it did when it was learned.
    if (skill.finalPkg.isNotEmpty && skill.finalSig.length >= 2) {
      final end = await _waitForScreen(
        skill.finalPkg,
        skill.finalSig,
        timeoutMs: 6000,
        minCoverage: skill.isTemplate ? 0.35 : 0.5,
      );
      if (end == null) {
        results.add('Replay finished but the final screen is not as recorded');
        return false;
      }
    }
    return true; // All steps succeeded
  }

  /// Returns predefined navigation steps for common tasks
  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    if (lower.contains('dark mode') || lower.contains('dark theme')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Display'}),
      ];
    }
    if (lower.contains('wifi') || lower.contains('wi-fi')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(
          action: 'click_text',
          params: {'text': 'Network & internet'},
        ),
      ];
    }
    if (lower.contains('bluetooth')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Connected devices'}),
      ];
    }

    final appPatterns = <String, List<String>>{
      'Settings': ['settings', 'brightness', 'display', 'notification'],
      'Play Store': [
        'play store',
        'playstore',
        'download',
        'install app',
        'google play',
      ],
      'YouTube': ['youtube'],
      'WhatsApp': ['whatsapp'],
      'Chrome': ['chrome', 'browse', 'search google'],
      'Camera': ['camera', 'take a photo', 'take photo', 'take a picture'],
      'Gallery': ['gallery', 'photos'],
      'Messages': ['message', 'sms', 'text to'],
      'Phone': ['call', 'dial'],
      'Gmail': ['gmail', 'email'],
      'Maps': ['maps', 'navigate to', 'directions'],
      'Clock': ['alarm', 'timer', 'stopwatch'],
      'Calculator': ['calculator', 'calculate', 'calc'],
    };

    for (final entry in appPatterns.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return [
            ActionStep(action: 'open_app', params: {'app_name': entry.key}),
          ];
        }
      }
    }

    // Generic fallback for "open X"
    final openMatch = RegExp(r'^open\s+([a-zA-Z0-9]+)').firstMatch(lower);
    if (openMatch != null) {
      String app = openMatch.group(1)!;
      app = app[0].toUpperCase() + app.substring(1);
      return [
        ActionStep(action: 'open_app', params: {'app_name': app}),
      ];
    }

    return null;
  }
}
