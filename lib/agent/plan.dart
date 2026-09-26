import 'json_utils.dart';

enum StepStatus { pending, running, done, failed, skipped }

/// Direct device actions a plan step may use (handled by ActionHandler).
const Set<String> kPlannableActions = {
  'open_app',
  'make_call',
  'send_sms',
  'search_contact',
  'set_alarm',
  'set_timer',
  'play_youtube',
  'play_favorite',
  'play_netflix',
  'play_favorite_netflix',
  'take_photo',
  'get_weather',
  'send_whatsapp',
  'send_ir',
  'save_ir',
  'set_volume',
  'set_brightness',
  'open_url',
  'send_email',
  'read_screen',
  'remember',
  'wait',
};

final RegExp _sensitiveWords = RegExp(
  r'\b(send|sends|sending|call|calling|pay|payment|buy|purchase|order|checkout|transfer|delete|remove|post|publish|tweet|uninstall|install|submit|book|subscribe|unsubscribe|confirm|withdraw)\b',
  caseSensitive: false,
);

class PlanStep {
  final String id;
  String title;

  /// 'ui' (screen-reading agent), 'action' (direct device call) or 'respond'.
  String kind;
  String expected;
  String action;
  Map<String, dynamic> params;
  bool sensitive;

  StepStatus status;
  int attempts;
  String result;

  PlanStep({
    required this.id,
    required this.title,
    this.kind = 'ui',
    this.expected = '',
    this.action = '',
    Map<String, dynamic>? params,
    this.sensitive = false,
    this.status = StepStatus.pending,
    this.attempts = 0,
    this.result = '',
  }) : params = params ?? <String, dynamic>{};

  factory PlanStep.fromLlm(Map<String, dynamic> json, int index) {
    var kind = JsonUtils.str(json['kind'], 'ui').toLowerCase();
    var action = JsonUtils.str(json['action']);
    final rawParams = json['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};
    if (kind != 'ui' && kind != 'action' && kind != 'respond') kind = 'ui';
    if (kind == 'action' && !kPlannableActions.contains(action)) {
      kind = 'ui';
      action = '';
    }
    final title = JsonUtils.str(
      json['title'],
      JsonUtils.str(json['step'], 'Step ${index + 1}'),
    );
    final explicit = json['sensitive'];
    var sensitive = explicit is bool ? explicit : false;
    if (explicit == null && kind != 'respond' && _sensitiveWords.hasMatch(title)) {
      sensitive = true;
    }
    if (kind == 'action' && (action == 'make_call' || action == 'send_sms' || action == 'send_email')) {
      sensitive = true;
    }
    return PlanStep(
      id: 's${index + 1}',
      title: title,
      kind: kind,
      expected: JsonUtils.str(json['expected']),
      action: action,
      params: params,
      sensitive: sensitive,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'kind': kind,
        'expected': expected,
        'action': action,
        'params': params,
        'sensitive': sensitive,
        'status': status.name,
        'attempts': attempts,
        'result': result,
      };

  factory PlanStep.fromJson(Map<String, dynamic> json) {
    final statusName = JsonUtils.str(json['status'], 'pending');
    return PlanStep(
      id: JsonUtils.str(json['id'], 's0'),
      title: JsonUtils.str(json['title'], 'Step'),
      kind: JsonUtils.str(json['kind'], 'ui'),
      expected: JsonUtils.str(json['expected']),
      action: JsonUtils.str(json['action']),
      params: json['params'] is Map
          ? Map<String, dynamic>.from(json['params'] as Map)
          : <String, dynamic>{},
      sensitive: JsonUtils.boolOf(json['sensitive']),
      status: StepStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => StepStatus.pending,
      ),
      attempts: json['attempts'] is num ? (json['attempts'] as num).toInt() : 0,
      result: JsonUtils.str(json['result']),
    );
  }
}

/// Lifecycle of a plan card in the chat.
enum PlanState { proposed, running, done, failed, cancelled, discarded }

class Plan {
  String goal;
  String summary;

  /// 'plan' (plan only) or 'planExecute' / 'auto'.
  String mode;
  List<PlanStep> steps;
  PlanState state;
  DateTime createdAt;

  /// Text produced when the run ended (answer or failure explanation).
  String outcome;

  Plan({
    required this.goal,
    this.summary = '',
    this.mode = 'planExecute',
    List<PlanStep>? steps,
    this.state = PlanState.proposed,
    DateTime? createdAt,
    this.outcome = '',
  })  : steps = steps ?? <PlanStep>[],
        createdAt = createdAt ?? DateTime.now();

  bool get awaitingApproval => state == PlanState.proposed;
  bool get isFinished =>
      state == PlanState.done ||
      state == PlanState.failed ||
      state == PlanState.cancelled ||
      state == PlanState.discarded;

  int get doneCount =>
      steps.where((s) => s.status == StepStatus.done || s.status == StepStatus.skipped).length;

  /// Builds a plan from the planner model's JSON. Never returns an empty plan.
  factory Plan.fromLlm(String goal, Map<String, dynamic>? json, {String mode = 'planExecute'}) {
    final steps = <PlanStep>[];
    final raw = json == null ? null : json['steps'];
    if (raw is List) {
      for (final entry in raw.take(10)) {
        if (entry is Map) {
          steps.add(PlanStep.fromLlm(Map<String, dynamic>.from(entry), steps.length));
        } else if (entry is String && entry.trim().isNotEmpty) {
          steps.add(PlanStep.fromLlm({'title': entry}, steps.length));
        }
      }
    }
    if (steps.isEmpty) {
      steps.add(PlanStep(id: 's1', title: goal, kind: 'ui'));
    }
    return Plan(
      goal: goal,
      summary: json == null ? goal : JsonUtils.str(json['summary'], goal),
      mode: mode,
      steps: steps,
    );
  }

  /// A one-step plan that simply runs [goal] on the screen agent.
  factory Plan.single(String goal, {String mode = 'auto'}) => Plan(
        goal: goal,
        summary: goal,
        mode: mode,
        steps: [PlanStep(id: 's1', title: goal, kind: 'ui')],
      );

  Map<String, dynamic> toJson() => {
        'goal': goal,
        'summary': summary,
        'mode': mode,
        'state': state.name,
        'outcome': outcome,
        'created_at': createdAt.toIso8601String(),
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory Plan.fromJson(Map<String, dynamic> json) {
    final stateName = JsonUtils.str(json['state'], 'proposed');
    final rawSteps = json['steps'];
    return Plan(
      goal: JsonUtils.str(json['goal']),
      summary: JsonUtils.str(json['summary']),
      mode: JsonUtils.str(json['mode'], 'planExecute'),
      state: PlanState.values.firstWhere(
        (s) => s.name == stateName,
        orElse: () => PlanState.proposed,
      ),
      outcome: JsonUtils.str(json['outcome']),
      createdAt: DateTime.tryParse(JsonUtils.str(json['created_at'])),
      steps: rawSteps is List
          ? rawSteps
              .whereType<Map>()
              .map((m) => PlanStep.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <PlanStep>[],
    );
  }

  /// Human-readable trace used by task history.
  List<String> traceLines() {
    return [
      for (final s in steps)
        '${s.id} [${s.status.name}] ${s.title}${s.result.isEmpty ? '' : ' → ${s.result}'}',
    ];
  }
}
