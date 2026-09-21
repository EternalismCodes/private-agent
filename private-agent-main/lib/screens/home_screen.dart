import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../services/action_handler.dart';
import '../services/voice_service.dart';
import '../widgets/message_bubble.dart';
import '../services/telegram_service.dart';
import '../services/chat_history_service.dart';
import '../services/notification_service.dart';
import 'settings_screen.dart';
import 'task_history_screen.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../main.dart';
import '../config/feature_flags.dart';
import '../agent/agent_context.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_mode.dart';
import '../agent/json_utils.dart';
import '../agent/plan.dart';
import '../agent/scheduler_service.dart';
import '../agent/skills_service.dart';
import 'agent_settings_screen.dart';
import 'call_screen.dart';
import 'memory_screen.dart';
import 'schedules_screen.dart';
import 'skills_screen.dart';
import 'vault_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AiService _aiService = AiService();
  final ActionHandler _actionHandler = ActionHandler();
  final VoiceService _voiceService = VoiceService();
  final NotificationService _notificationService = NotificationService();
  late final TelegramService _telegramService;

  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isListening = false;

  // Current interaction mode (Chat, Think, Plan, Plan & Execute, Auto)
  AgentMode _mode = AgentMode.auto;

  late final AgentContext _agentContext;
  late final AgentController _controller;
  String _progress = '';
  bool _inCall = false;

  // Chat Session state tracking
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
  String _sessionTitle = '';

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  Timer? _overlayHistoryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _telegramService = TelegramService(_actionHandler, _aiService);
    _agentContext = AgentContext(ai: _aiService, actions: _actionHandler);
    _controller = AgentController(_agentContext);
    _startScheduler();
    _initServices();
    _startOverlayHistorySync();
    // Register as the handler for overlay bubble tasks
    onOverlayTask = (task) => _sendMessage(task);
  }

  Future<void> _initServices() async {
    await _aiService.init();
    await _notificationService.requestPermission();
    await _voiceService.init();
    await _telegramService.init();
    await _actionHandler.shizuku.checkAvailability();
    await _agentContext.ensureLoaded();
    _mode = _agentContext.prefs.defaultMode;

    if (mounted) {
      setState(() {});
    }
  }

  // ─── Scheduled tasks ────────────────────────────────────────────────────

  bool _canRunScheduled() => mounted && !_isLoading && !_inCall && !_controller.busy;

  void _startScheduler() {
    final scheduler = SchedulerService.instance;
    unawaited(scheduler.syncAlarms());
    scheduler.start(canRun: _canRunScheduled, runner: _runScheduledTask);
  }

  Future<String> _runScheduledTask(ScheduledTask task) async {
    if (!mounted) return 'Skipped';
    setState(() {
      _messages.add(
        ChatMessage(role: 'user', content: '⏰ Scheduled task: ${task.goal}', mode: 'auto'),
      );
      _isLoading = true;
    });
    _scrollToBottom();

    var status = 'Success';
    var reply = '';
    // Each schedule may use its own model; it applies to this run only.
    _aiService.modelOverride = task.model.trim().isEmpty ? null : task.model.trim();
    try {
      final result = await _controller.handle(
        task.goal,
        task.agentMode == AgentMode.planExecute ? AgentMode.planExecute : AgentMode.auto,
        _ui,
        unattended: !task.askFirst,
      );
      status = result.success ? 'Success' : 'Failed';
      reply = result.reply;
    } catch (e) {
      status = 'Failed';
      reply = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _aiService.modelOverride = null;
      await _saveSession();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _progress = '';
        });
      }
    }

    // The user is probably not looking at the screen: report the outcome.
    try {
      final goal = task.goal.length > 40 ? '${task.goal.substring(0, 40)}…' : task.goal;
      final body = reply.isEmpty ? status : (reply.length > 180 ? '${reply.substring(0, 180)}…' : reply);
      await _notificationService.showTaskCompleteNotification(
        status == 'Success' ? 'Scheduled: $goal' : 'Scheduled task failed: $goal',
        body,
      );
    } catch (_) {}
    return status;
  }

  // ─── Bridge between the agent controller and this screen ────────────────

  late final AgentUi _ui = AgentUi(
    addMessage: (m) {
      if (mounted) setState(() => _messages.add(m));
      _scrollToBottom();
      return m;
    },
    refresh: () {
      if (mounted) setState(() {});
      _scrollToBottom();
    },
    removeMessage: (m) {
      if (mounted) setState(() => _messages.remove(m));
    },
    confirmStep: _confirmStep,
    onProgress: (msg) {
      developer.log('Task progress: $msg', name: 'PrivateAgent');
      _sendOverlayEvent('OVERLAY_PROGRESS', msg);
      if (mounted) setState(() => _progress = msg);
    },
  );

  /// Asks before a sensitive step. The agent may have moved to another app, so
  /// PrivateAgent is brought back to the front first; no answer within 90s
  /// counts as "no".
  Future<bool> _confirmStep(PlanStep step) async {
    if (!mounted) return false;
    try {
      await _notificationService.showTaskCompleteNotification(
        'Confirmation needed',
        step.title,
      );
    } catch (_) {}
    try {
      await _actionHandler.appLauncher.openPackage('com.orailnoor.privateagent');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return false;

    var open = true;
    final dialog = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow this step?'),
        content: Text(step.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    );
    final timer = Timer(const Duration(seconds: 90), () {
      if (open && mounted) Navigator.of(context, rootNavigator: true).pop(false);
    });
    final answer = await dialog;
    open = false;
    timer.cancel();
    return answer == true;
  }

  Future<void> _saveSession() async {
    if (_messages.isEmpty) return;

    // Set first user message as session title if not set
    if (_sessionTitle.isEmpty) {
      final firstUserMsg = _messages.firstWhere(
        (m) => m.isUser,
        orElse: () => ChatMessage(role: 'user', content: 'New Chat'),
      );
      _sessionTitle = firstUserMsg.content.length > 28
          ? '${firstUserMsg.content.substring(0, 25)}...'
          : firstUserMsg.content;
    }

    final session = ChatSession(
      id: _sessionId,
      title: _sessionTitle,
      timestamp: DateTime.now(),
      messages: _messages.map((m) => m.toJson()).toList(),
    );

    await ChatHistoryService.saveSession(session);
  }

  Future<void> _sendMessage(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || _isLoading) return;

    final userMessage = ChatMessage(role: 'user', content: clean, mode: _mode.id);
    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
      _progress = '';
    });
    _updateOverlayState();
    _textController.clear();
    _scrollToBottom();
    await _saveSession();

    try {
      final result = await _controller.handle(clean, _mode, _ui);
      if (result.speak && _agentContext.prefs.speakReplies && result.reply.isNotEmpty) {
        unawaited(_voiceService.speak(JsonUtils.forSpeech(result.reply)));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: 'Error: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
          );
        });
      }
    } finally {
      await _saveSession();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _progress = '';
        });
        _scrollToBottom();
        _updateOverlayState();
      }
    }
  }

  // ─── Plan card actions ──────────────────────────────────────────────────

  Future<void> _approvePlan(ChatMessage message) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _progress = '';
    });
    await _saveSession();
    try {
      final result = await _controller.executePlan(message, _ui);
      if (result.speak && _agentContext.prefs.speakReplies && result.reply.isNotEmpty) {
        unawaited(_voiceService.speak(JsonUtils.forSpeech(result.reply)));
      }
    } finally {
      await _saveSession();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _progress = '';
        });
        _scrollToBottom();
      }
    }
  }

  void _discardPlan(ChatMessage message) {
    setState(() => message.plan?.state = PlanState.discarded);
    _saveSession();
  }

  void _removePlanStep(ChatMessage message, PlanStep step) {
    setState(() => message.plan?.steps.remove(step));
    _saveSession();
  }

  Future<void> _editPlanStep(ChatMessage message, PlanStep step) async {
    final controller = TextEditingController(text: step.title);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit step'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved == true && controller.text.trim().isNotEmpty) {
      setState(() => step.title = controller.text.trim());
      await _saveSession();
    }
  }

  Future<void> _saveAsSkill(ChatMessage message) async {
    final plan = message.plan;
    if (plan == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Turning this into a skill…')));
    final skill = await SkillsService.instance.distill(
      _agentContext.llm,
      goal: plan.goal,
      trace: plan.traceLines(),
    );
    if (skill == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not create a skill from this run.')));
      return;
    }
    await SkillsService.instance.save(skill);
    messenger.showSnackBar(SnackBar(content: Text('Saved skill "${skill.name}"')));
  }

  Future<void> _startCall() async {
    if (_isLoading || _inCall) return;
    if (!_aiService.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add your API key in Settings first.')),
      );
      return;
    }
    _inCall = true;
    final transcript = await Navigator.push<List<ChatMessage>>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CallScreen(
          controller: _controller,
          voice: _voiceService,
        ),
      ),
    );
    _inCall = false;
    if (transcript != null && transcript.isNotEmpty && mounted) {
      setState(() => _messages.addAll(transcript));
      await _saveSession();
      _scrollToBottom();
    }
  }

  Future<void> _openAgentScreen(Widget screen) async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (result is String && result.isNotEmpty && mounted) {
      setState(() => _mode = AgentMode.auto);
      await _sendMessage(result);
    }
  }

  Future<void> _showTaskProgressOverlay(String message) async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;

    // Never cover PrivateAgent itself. The lifecycle observer will create the
    // overlay after an automated action moves this app to the background.
    if (_appLifecycleState != AppLifecycleState.paused) return;

    if (!await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'PrivateAgent',
        overlayContent: 'Performing task...',
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // Keep the overlay minimized during automation. The user can still tap the
    // bubble to open the full conversation whenever they choose.
    _sendOverlayEvent('OVERLAY_TASK_STARTED', message);
  }

  void _sendOverlayEvent(String type, String message) {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final safeMessage = message.replaceAll('|', ' ');
    unawaited(
      FlutterOverlayWindow.shareData(
        '$type|$safeMessage',
      ).timeout(const Duration(seconds: 2)).catchError((Object _) {}),
    );
  }

  Future<void> _sendOverlayHistorySnapshot() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final history = base64Encode(
      utf8.encode(
        jsonEncode(_messages.map((message) => message.toJson()).toList()),
      ),
    );
    try {
      await FlutterOverlayWindow.shareData(
        'OVERLAY_HISTORY|$history',
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleVoice() async {
    if (_isListening) {
      await _voiceService.stopListening();
      setState(() => _isListening = false);
      return;
    }

    setState(() => _isListening = true);

    await _voiceService.startListening(
      onResult: (text) {
        _sendMessage(text);
      },
      onDone: () {
        if (mounted) {
          setState(() => _isListening = false);
        }
      },
    );
  }

  void _startNewChat() {
    setState(() {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionTitle = '';
      _messages.clear();
      _aiService.clearHistory();
      _controller.resetHistory();
    });
  }

  void _loadChatSession(ChatSession session) {
    setState(() {
      _sessionId = session.id;
      _sessionTitle = session.title;
      _messages.clear();
      for (final m in session.messages) {
        _messages.add(ChatMessage.fromJson(m));
      }

      _aiService.clearHistory();
      for (final m in _messages) {
        if (m.actionResult != null) continue;
        _aiService.addHistoryMessage(m.role, m.content);
        // A plan that was mid-run when the app closed can no longer continue.
        final plan = m.plan;
        if (plan != null && plan.state == PlanState.running) {
          plan.state = PlanState.failed;
          plan.outcome = 'Interrupted.';
          for (final step in plan.steps) {
            if (step.status == StepStatus.running) step.status = StepStatus.pending;
          }
        }
      }
      _controller.seedHistory(_messages);
    });
    _scrollToBottom();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlayHistoryTimer?.cancel();
    SchedulerService.instance.stop();
    _textController.dispose();
    _scrollController.dispose();
    _voiceService.dispose();
    _telegramService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _appLifecycleState = state;
    });
    if (state == AppLifecycleState.resumed) {
      unawaited(
        SchedulerService.instance.checkDue(
          canRun: _canRunScheduled,
          runner: _runScheduledTask,
        ),
      );
      _startOverlayHistorySync();
      unawaited(_handleAppForegrounded());
    } else {
      _overlayHistoryTimer?.cancel();
      _updateOverlayState();
    }
  }

  void _startOverlayHistorySync() {
    _overlayHistoryTimer?.cancel();
    if (!FeatureFlags.floatingOverlayEnabled) return;
    unawaited(_importOverlayChatHistory());
    _overlayHistoryTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (_appLifecycleState == AppLifecycleState.resumed) {
        unawaited(_importOverlayChatHistory());
      }
    });
  }

  Future<void> _handleAppForegrounded() async {
    await _updateOverlayState();
    await _importOverlayChatHistory();
  }

  Future<void> _importOverlayChatHistory() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    if (_importingOverlayHistory) return;
    _importingOverlayHistory = true;
    try {
      final handoff = await ChatHistoryService.consumeOverlayMessages();
      if (!mounted || handoff.isEmpty) return;

      final imported = handoff.map(ChatMessage.fromJson).toList();
      for (final message in imported) {
        if (message.actionResult == null) {
          _aiService.addHistoryMessage(message.role, message.content);
        }
      }
      setState(() {
        _messages.addAll(imported);
      });
      _scrollToBottom();
      await _saveSession();
    } finally {
      _importingOverlayHistory = false;
    }
  }

  int _overlayUpdateGeneration = 0;
  bool _importingOverlayHistory = false;

  Future<void> _updateOverlayState() async {
    if (!FeatureFlags.floatingOverlayEnabled) return;
    final generation = ++_overlayUpdateGeneration;
    final isBackground = _appLifecycleState == AppLifecycleState.paused;
    final shouldBeActive = isBackground;

    bool granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted || generation != _overlayUpdateGeneration) return;

    bool active = await FlutterOverlayWindow.isActive();
    if (generation != _overlayUpdateGeneration) return;
    if (shouldBeActive && !active) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState != AppLifecycleState.paused) return;
      if (await FlutterOverlayWindow.isActive()) return;
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: "PrivateAgent",
        overlayContent: _isLoading
            ? "Performing task..."
            : "Floating Assistant",
        flag: OverlayFlag.focusPointer,
        alignment: OverlayAlignment.centerRight,
        visibility: NotificationVisibility.visibilitySecret,
        positionGravity: PositionGravity.auto,
        startPosition: const OverlayPosition(0, 200),
        width: 56,
        height: 56,
      );
      if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
        // Give the overlay isolate time to attach its listener, then send the
        // full active conversation. A second snapshot makes cold starts
        // reliable without duplicating messages because the overlay replaces
        // its list atomically.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _sendOverlayHistorySnapshot();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_isLoading && _appLifecycleState == AppLifecycleState.paused) {
          await _sendOverlayHistorySnapshot();
        }
      }
    } else if (shouldBeActive && active && _isLoading) {
      await _sendOverlayHistorySnapshot();
    } else if (!shouldBeActive && active) {
      try {
        await FlutterOverlayWindow.shareData(
          'OVERLAY_RESET|',
        ).timeout(const Duration(milliseconds: 150));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (generation != _overlayUpdateGeneration) return;
      if (_appLifecycleState == AppLifecycleState.paused) return;
      await FlutterOverlayWindow.closeOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0C0A15)
          : const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 20,
              color: isDark ? Colors.white : const Color(0xFF1E293B),
            ),
            children: [
              TextSpan(
                text: 'Private',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: -0.5,
                ),
              ),
              const TextSpan(
                text: 'Agent',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu_rounded),
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded),
            tooltip: 'Talk to the agent',
            onPressed: _isLoading ? null : _startCall,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: _isLoading ? null : _startNewChat,
          ),
          // Settings Action
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
              await _actionHandler.shizuku.checkAvailability();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      drawer: _buildDrawer(context, isDark),
      body: Stack(
        children: [
          // Background mesh glows
          _buildBackgroundGlows(isDark),

          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(color: Colors.transparent),
            ),
          ),

          Column(
            children: [
              // Pill selector switcher
              _buildModeSelector(isDark),

              // API key warning banner
              if (!_aiService.isConfigured)
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.orangeAccent.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'API not configured. Tap Settings to add details.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SettingsScreen(
                                aiService: _aiService,
                                shizukuService: _actionHandler.shizuku,
                                screenAutomationService:
                                    _actionHandler.screenAutomation,
                                telegramService: _telegramService,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        child: const Text('Configure'),
                      ),
                    ],
                  ),
                ),

              // Chat content area
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(isDark)
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          return MessageBubble(
                            key: ObjectKey(message),
                            message: message,
                            onApprovePlan: () => _approvePlan(message),
                            onDiscardPlan: () => _discardPlan(message),
                            onEditStep: (step) => _editPlanStep(message, step),
                            onRemoveStep: (step) => _removePlanStep(message, step),
                            onSaveSkill: () => _saveAsSkill(message),
                          );
                        },
                      ),
              ),

              // Think loading indicator
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.indigoAccent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                        _progress.isEmpty ? 'Thinking...' : _progress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF9E9BAC)
                              : const Color(0xFF6C6A7C),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () {
                          _controller.cancel();
                          _actionHandler.cancelTask();
                          setState(() {
                            _progress = 'Stopping...';
                          });
                        },
                        icon: const Icon(
                          Icons.stop_circle_rounded,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        label: const Text(
                          'Stop',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),

              // Custom Input bar
              _buildInputBar(isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context, bool isDark) {
    final drawerBg = isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC);
    final textStyle = TextStyle(
      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
      fontWeight: FontWeight.w600,
      fontSize: 13.5,
    );
    final headerStyle = TextStyle(
      color: isDark ? Colors.white : const Color(0xFF1E293B),
      fontSize: 17,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
    );

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          // Drawer Header
          Container(
            padding: const EdgeInsets.only(
              top: 60,
              bottom: 20,
              left: 24,
              right: 24,
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_rounded,
                  color: Theme.of(context).primaryColor,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Text('PrivateAgent', style: headerStyle),
              ],
            ),
          ),

          // New Chat Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.pop(context); // Close drawer
                    _startNewChat();
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_comment_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'New Chat',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          // Section CHAT HISTORY
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'CHAT HISTORY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).primaryColor,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),

          // Chat Sessions List
          Expanded(
            child: FutureBuilder<List<ChatSession>>(
              future: ChatHistoryService.loadSessions(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Center(
                    child: Text(
                      'No recent chats',
                      style: TextStyle(
                        color: isDark ? Colors.grey[800] : Colors.grey[400],
                        fontSize: 12,
                      ),
                    ),
                  );
                }

                final sessions = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isCurrent = session.id == _sessionId;

                    return Container(
                      margin: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? Theme.of(
                                context,
                              ).colorScheme.primary.withOpacity(0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isCurrent
                            ? Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withOpacity(0.15),
                              )
                            : null,
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 0,
                        ),
                        dense: true,
                        leading: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 15,
                          color: isCurrent
                              ? Theme.of(context).colorScheme.primary
                              : (isDark ? Colors.grey[600] : Colors.grey[500]),
                        ),
                        title: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle.copyWith(
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isCurrent
                                ? (isDark
                                      ? Colors.white
                                      : const Color(0xFF1E293B))
                                : null,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: Colors.redAccent.withOpacity(0.7),
                          ),
                          onPressed: () async {
                            await ChatHistoryService.deleteSession(session.id);
                            if (isCurrent) {
                              _startNewChat();
                            }
                            (context as Element)
                                .markNeedsBuild(); // Re-trigger build refresh
                          },
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _loadChatSession(session);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 20),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'AGENT',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).primaryColor,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
          _drawerTile(Icons.psychology_alt_outlined, 'Memory', textStyle, isDark, () {
            Navigator.pop(context);
            _openAgentScreen(const MemoryScreen());
          }),
          _drawerTile(Icons.extension_outlined, 'Skills & workflows', textStyle, isDark, () {
            Navigator.pop(context);
            _openAgentScreen(const SkillsScreen());
          }),
          _drawerTile(Icons.schedule_rounded, 'Schedules', textStyle, isDark, () {
            Navigator.pop(context);
            _openAgentScreen(
              SchedulesScreen(
                aiService: _aiService,
                onRunNow: (goal) async {
                  if (!mounted) return;
                  setState(() => _mode = AgentMode.auto);
                  await _sendMessage(goal);
                },
              ),
            );
          }),
          _drawerTile(Icons.key_rounded, 'Accounts', textStyle, isDark, () {
            Navigator.pop(context);
            _openAgentScreen(const VaultScreen());
          }),
          _drawerTile(Icons.tune_rounded, 'Agent preferences', textStyle, isDark, () async {
            Navigator.pop(context);
            await _openAgentScreen(const AgentSettingsScreen());
            if (mounted) setState(() {});
          }),
          const Divider(indent: 16, endIndent: 16, height: 12),

          // Section TASKS & SETTINGS
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.history_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Task History', style: textStyle),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TaskHistoryScreen()),
              );
            },
          ),
          ListTile(
            horizontalTitleGap: 8,
            leading: Icon(
              Icons.settings_rounded,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
              size: 20,
            ),
            title: Text('Settings', style: textStyle),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    aiService: _aiService,
                    shizukuService: _actionHandler.shizuku,
                    screenAutomationService: _actionHandler.screenAutomation,
                    telegramService: _telegramService,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBackgroundGlows(bool isDark) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            top: -150,
            left: -50,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0.24)
                        : const Color(0xFF4F46E5).withOpacity(0.12),
                    isDark
                        ? const Color(0xFF6366F1).withOpacity(0)
                        : const Color(0xFF4F46E5).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 50,
            right: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0.18)
                        : const Color(0xFF0EA5E9).withOpacity(0.09),
                    isDark
                        ? const Color(0xFF38BDF8).withOpacity(0)
                        : const Color(0xFF0EA5E9).withOpacity(0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawerTile(
    IconData icon,
    String title,
    TextStyle textStyle,
    bool isDark,
    VoidCallback onTap,
  ) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      horizontalTitleGap: 8,
      leading: Icon(icon, color: isDark ? Colors.grey[400] : Colors.grey[600], size: 20),
      title: Text(title, style: textStyle),
      onTap: onTap,
    );
  }

  Widget _buildModeSelector(bool isDark) {
    final scheme = Theme.of(context).colorScheme;
    final idle = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
    final chipBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            itemCount: AgentMode.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final mode = AgentMode.values[index];
              final selected = _mode == mode;
              return GestureDetector(
                onTap: _isLoading ? null : () => setState(() => _mode = mode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: selected ? scheme.primary : chipBg,
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: scheme.primary.withOpacity(0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(mode.icon, size: 15, color: selected ? Colors.white : idle),
                      const SizedBox(width: 6),
                      Text(
                        mode.shortLabel,
                        style: TextStyle(
                          color: selected ? Colors.white : idle,
                          fontWeight: FontWeight.bold,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text(
            _mode.description,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: idle.withOpacity(0.85)),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final time = DateTime.now();
    String timeGreeting = 'Hello';
    if (time.hour >= 5 && time.hour < 12) {
      timeGreeting = 'Hello, good morning.';
    } else if (time.hour >= 12 && time.hour < 17) {
      timeGreeting = 'Hello, good afternoon.';
    } else if (time.hour >= 17 && time.hour < 22) {
      timeGreeting = 'Hello, good evening.';
    } else {
      timeGreeting = 'Hello.';
    }

    final List<String> suggestions = switch (_mode) {
      AgentMode.chat => [
          'Write a professional email',
          'Explain quantum computing simply',
          'Brainstorm mobile app ideas',
          'Write a poem about robots',
        ],
      AgentMode.think => [
          'Is it cheaper to rent or buy over 3 years?',
          'Plan a fair way to split a group trip budget',
          'Find the flaw in this argument: all birds fly',
          'Compare two job offers step by step',
        ],
      AgentMode.plan => [
          'Plan how to send photos to Mom on WhatsApp',
          'Plan a morning routine using my phone',
          'Plan: find a nearby pharmacy and call it',
          'Plan how to free up storage on my phone',
        ],
      AgentMode.planExecute => [
          'Open YouTube and play lo-fi music',
          'Check the weather and text Mom if it will rain',
          'Turn on dark mode and lower the brightness',
          'Find the top news headline in Chrome',
        ],
      AgentMode.auto => [
          'Open YouTube and search for cats',
          'Call Mom',
          'Remind me to drink water every 2 hours',
          "What's on my screen?",
        ],
    };

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    timeGreeting,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                      letterSpacing: -1.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'How can I help you?',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: -1.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SUGGESTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569),
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = suggestions[index];
                  return Container(
                    margin: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      onTap: () => _sendMessage(suggestion),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF151D30)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF243049).withOpacity(0.4)
                                : const Color(0xFFE2E8F0),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(
                                isDark ? 0.1 : 0.02,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            suggestion,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFFF8FAFC)
                                  : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          // Glowing Voice Mic button
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isListening
                  ? Colors.redAccent
                  : Theme.of(context).cardTheme.color,
              border: Border.all(
                color: _isListening
                    ? Colors.redAccent
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
                if (_isListening)
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
              ],
            ),
            child: IconButton(
              icon: Icon(
                _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: _isListening
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
              onPressed: _isLoading ? null : _toggleVoice,
            ),
          ),
          const SizedBox(width: 10),

          // Custom Text input container
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.08),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: _isListening
                            ? 'Listening...'
                            : '${_mode.label}: ask or command...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.grey[600] : Colors.grey[400],
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        border: InputBorder.none,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _isLoading
                          ? null
                          : (text) => _sendMessage(text),
                    ),
                  ),

                  // Solid Send button
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.send_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      onPressed: _isLoading
                          ? null
                          : () => _sendMessage(_textController.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
