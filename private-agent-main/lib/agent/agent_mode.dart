import 'package:flutter/material.dart';

/// The five ways the user can talk to PrivateAgent.
enum AgentMode { chat, think, plan, planExecute, auto }

extension AgentModeInfo on AgentMode {
  String get id => name;

  String get label => switch (this) {
        AgentMode.chat => 'Chat',
        AgentMode.think => 'Think',
        AgentMode.plan => 'Plan',
        AgentMode.planExecute => 'Plan & Execute',
        AgentMode.auto => 'Auto',
      };

  String get shortLabel => switch (this) {
        AgentMode.chat => 'Chat',
        AgentMode.think => 'Think',
        AgentMode.plan => 'Plan',
        AgentMode.planExecute => 'Plan & Run',
        AgentMode.auto => 'Auto',
      };

  String get description => switch (this) {
        AgentMode.chat => 'Fast conversation. No phone control.',
        AgentMode.think => 'Reasons step by step before answering. No phone control.',
        AgentMode.plan => 'Writes a step-by-step plan. Nothing is executed until you say so.',
        AgentMode.planExecute => 'Shows a plan for approval, then runs it with verification and recovery.',
        AgentMode.auto => 'Decides by itself: answers, acts, or plans and executes.',
      };

  IconData get icon => switch (this) {
        AgentMode.chat => Icons.chat_bubble_outline_rounded,
        AgentMode.think => Icons.psychology_outlined,
        AgentMode.plan => Icons.checklist_rounded,
        AgentMode.planExecute => Icons.play_circle_outline_rounded,
        AgentMode.auto => Icons.auto_awesome_rounded,
      };

  /// Modes that are allowed to operate the phone.
  bool get canControlDevice =>
      this == AgentMode.planExecute || this == AgentMode.auto;

  static AgentMode fromId(String? id) {
    for (final mode in AgentMode.values) {
      if (mode.name == id) return mode;
    }
    return AgentMode.auto;
  }
}
