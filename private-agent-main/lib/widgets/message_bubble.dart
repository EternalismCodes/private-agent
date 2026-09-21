import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/chat_message.dart';
import '../agent/plan.dart';
import 'agent_widgets.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onApprovePlan;
  final VoidCallback? onDiscardPlan;
  final void Function(PlanStep step)? onEditStep;
  final void Function(PlanStep step)? onRemoveStep;
  final VoidCallback? onSaveSkill;

  const MessageBubble({
    super.key,
    required this.message,
    this.onApprovePlan,
    this.onDiscardPlan,
    this.onEditStep,
    this.onRemoveStep,
    this.onSaveSkill,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width *
              (message.plan != null ? 0.94 : 0.8),
        ),
        margin: EdgeInsets.only(
          left: isUser ? 48 : 8,
          right: isUser ? 8 : 48,
          top: 4,
          bottom: 4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(isUser ? 20 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 20),
          ),
          border: isUser
              ? null
              : Border.all(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                  width: 1.2,
                ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(Theme.of(context).brightness == Brightness.dark ? 0.15 : 0.02),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Action result badge
            if (message.actionResult != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: message.actionResult!.success
                      ? Colors.green.withOpacity(0.12)
                      : Colors.red.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: message.actionResult!.success
                        ? Colors.green.withOpacity(0.3)
                        : Colors.red.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      message.actionResult!.success
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      size: 14,
                      color: message.actionResult!.success
                          ? Colors.green
                          : Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      message.actionResult!.actionType.toUpperCase().replaceAll('_', ' '),
                      style: TextStyle(
                        fontSize: 10,
                        color: message.actionResult!.success
                            ? Colors.green
                            : Colors.red,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Reasoning (Think mode)
            if (!isUser && message.reasoning.isNotEmpty)
              ReasoningBlock(text: message.reasoning, thinking: message.thinking),
            // Message text
            if (!isUser && message.content.isEmpty && message.plan == null && message.reasoning.isEmpty)
              Text(
                '…',
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              )
            else if (isUser)
              SelectableText(
                message.content,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 15,
                  height: 1.4,
                ),
              )
            else
              MarkdownBody(
                data: message.content,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 15,
                    height: 1.45,
                  ),
                  listBullet: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 15,
                  ),
                ),
              ),
            if (message.plan != null)
              PlanCard(
                plan: message.plan!,
                onApprove: onApprovePlan,
                onDiscard: onDiscardPlan,
                onEditStep: onEditStep,
                onRemoveStep: onRemoveStep,
                onSaveSkill: onSaveSkill,
              ),
            // Timestamp
            const SizedBox(height: 4),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: 11,
                color: isUser
                    ? Theme.of(context)
                        .colorScheme
                        .onPrimary
                        .withValues(alpha: 0.6)
                    : Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
