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
    final savedSkill = await _skillMemory.findSkill(userGoal);
    if (savedSkill != null && savedSkill.isReliable) {
      _report(
        'Found saved skill! Replaying ${savedSkill.steps.length} steps...',
      );
      final replaySuccess = await _replaySkill(savedSkill, results);
      if (replaySuccess) {
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
        return 'Done.';
      } else {
        _report('Replay failed, falling back to AI...');
        await _skillMemory.recordFailure(savedSkill.id);
      }
    }

    // Smart pre-launch shortcuts: execute common sequences without LLM
    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';
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
      await Future.delayed(Duration(milliseconds: delay));

      // 1. Read the current screen text
      final screenContent = _aiService.useScreenCompression
          ? await _screenService.getCompressedScreenDescription(userGoal)
          : await _screenService.getScreenDescription();
      developer.log(
        '=== SCREEN DUMP (Step ${step + 1}) ===\n$screenContent',
        name: 'PrivateAgent',
      );

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
$screenContent$prevResultStr$failureHint
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
      final isComplete = actionJson['is_complete'] == true;

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

      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;

        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
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
          final startX = (params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (params['endY'] as num?)?.toDouble() ?? 500;

          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;

        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
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
        executedSteps.add(ActionStep(action: action, params: params));
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      // Provide progress feedback
      if (!isComplete && (step + 1) % 3 == 0) {
        await _toast('Working... (Step ${step + 1})');
      }

      if (isComplete) {
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

        // Save to skill memory
        await _skillMemory.saveSkill(userGoal, executedSteps);

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
  Future<bool> _replaySkill(SavedSkill skill, List<String> results) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) return false;

      final step = skill.steps[i];
      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');

      // Delay before executing each step
      int delay = 1200;
      if (step.action == 'open_app')
        delay = 3000;
      else if (step.action == 'type_text')
        delay = 2000;
      else if (step.action == 'click_text' || step.action == 'click_at')
        delay = 1500;
      else if (step.action == 'scroll')
        delay = 1000;

      await Future.delayed(Duration(milliseconds: delay));

      bool success = false;
      String actionResult = '';

      switch (step.action) {
        case 'click_text':
          final text = step.params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;
        case 'click_at':
          final x = (step.params['x'] as num?)?.toDouble() ?? 0;
          final y = (step.params['y'] as num?)?.toDouble() ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;
        case 'type_text':
          final text = step.params['text'] as String? ?? '';
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
          final startX = (step.params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (step.params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (step.params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (step.params['endY'] as num?)?.toDouble() ?? 500;
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
