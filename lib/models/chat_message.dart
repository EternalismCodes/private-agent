import '../agent/plan.dart';

class ChatMessage {
  final String role; // 'user' or 'assistant'

  // Mutable so streamed answers and live plan cards can update in place.
  String content;
  final DateTime timestamp;
  final AgentActionResult? actionResult;

  /// The model's visible reasoning (Think mode), shown in a collapsible block.
  String reasoning;

  /// True while the model is still producing reasoning.
  bool thinking;

  /// A plan card attached to this message (Plan / Plan & Execute / Auto).
  Plan? plan;

  /// Which mode produced the message (chat, think, plan, planExecute, auto).
  String? mode;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.actionResult,
    this.reasoning = '',
    this.thinking = false,
    this.plan,
    this.mode,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'actionResult': actionResult?.toJson(),
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (plan != null) 'plan': plan!.toJson(),
        if (mode != null) 'mode': mode,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String,
        content: json['content'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        actionResult: json['actionResult'] != null
            ? AgentActionResult.fromJson(json['actionResult'] as Map<String, dynamic>)
            : null,
        reasoning: (json['reasoning'] as String?) ?? '',
        plan: json['plan'] is Map
            ? Plan.fromJson(Map<String, dynamic>.from(json['plan'] as Map))
            : null,
        mode: json['mode'] as String?,
      );
}

class AgentActionResult {
  final String actionType;
  final bool success;
  final String? details;

  AgentActionResult({
    required this.actionType,
    required this.success,
    this.details,
  });

  Map<String, dynamic> toJson() => {
        'actionType': actionType,
        'success': success,
        'details': details,
      };

  factory AgentActionResult.fromJson(Map<String, dynamic> json) => AgentActionResult(
        actionType: json['actionType'] as String,
        success: json['success'] as bool,
        details: json['details'] as String?,
      );
}
