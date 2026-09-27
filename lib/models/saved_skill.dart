import 'dart:convert';

class ActionStep {
  final String action;
  final Map<String, dynamic> params;

  /// Exact-replay data recorded with the step: app package, screen signature,
  /// tapped target (label, class, centre coordinates). Empty for steps saved
  /// by older versions, which are replayed with fixed delays instead.
  final Map<String, dynamic> meta;

  ActionStep({
    required this.action,
    required this.params,
    Map<String, dynamic>? meta,
  }) : meta = meta ?? <String, dynamic>{};

  factory ActionStep.fromJson(Map<String, dynamic> json) {
    return ActionStep(
      action: json['action'] as String? ?? '',
      params: json['params'] as Map<String, dynamic>? ?? {},
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'action': action,
      'params': params,
      if (meta.isNotEmpty) 'meta': meta,
    };
  }
}

class SavedSkill {
  final String id;
  final String task;
  final List<String> taskKeywords;
  int successCount;
  int failCount;
  DateTime lastUsed;
  final List<ActionStep> steps;

  /// Screen the workflow ended on (app package and label signature); used to
  /// confirm a replay reached the same result without asking the model.
  String finalPkg;
  List<String> finalSig;

  /// How many times the workflow was replayed instantly, and how long the last
  /// replay took.
  int replayCount;
  int lastReplayMs;

  /// Parameterised workflows: the words that identify the task (for example
  /// [youtube, search]) and the example value that was typed ("cats videos").
  /// A request with the same skeleton and a different value reuses the steps.
  List<String> skeleton;
  String slotExample;

  SavedSkill({
    required this.id,
    required this.task,
    required this.taskKeywords,
    this.successCount = 0,
    this.failCount = 0,
    required this.lastUsed,
    required this.steps,
    this.finalPkg = '',
    List<String>? finalSig,
    this.replayCount = 0,
    this.lastReplayMs = 0,
    List<String>? skeleton,
    this.slotExample = '',
  })  : finalSig = finalSig ?? <String>[],
        skeleton = skeleton ?? <String>[];

  bool get isTemplate => skeleton.length >= 2 && slotExample.isNotEmpty;

  /// True when every step carries exact-replay data.
  bool get isExact => steps.isNotEmpty && steps.every((s) => s.meta.isNotEmpty || s.action == 'open_app');

  bool get isReliable => successCount >= 1 && (failCount / (successCount + failCount)) < 0.3;

  factory SavedSkill.fromJson(Map<String, dynamic> json) {
    return SavedSkill(
      id: json['id'] as String,
      task: json['task'] as String,
      taskKeywords: List<String>.from(json['task_keywords'] ?? []),
      successCount: json['success_count'] as int? ?? 0,
      failCount: json['fail_count'] as int? ?? 0,
      lastUsed: DateTime.parse(json['last_used'] as String),
      steps: (json['steps'] as List).map((s) => ActionStep.fromJson(s as Map<String, dynamic>)).toList(),
      finalPkg: json['final_pkg'] as String? ?? '',
      finalSig: List<String>.from(json['final_sig'] ?? []),
      replayCount: json['replay_count'] as int? ?? 0,
      lastReplayMs: json['last_replay_ms'] as int? ?? 0,
      skeleton: List<String>.from(json['skeleton'] ?? []),
      slotExample: json['slot_example'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'task': task,
      'task_keywords': taskKeywords,
      'success_count': successCount,
      'fail_count': failCount,
      'last_used': lastUsed.toIso8601String(),
      'steps': steps.map((s) => s.toJson()).toList(),
      'final_pkg': finalPkg,
      'final_sig': finalSig,
      'replay_count': replayCount,
      'last_replay_ms': lastReplayMs,
      'skeleton': skeleton,
      'slot_example': slotExample,
    };
  }
}
