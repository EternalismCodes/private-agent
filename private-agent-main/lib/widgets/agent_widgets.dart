import 'package:flutter/material.dart';
import '../agent/plan.dart';

/// Collapsible "thought process" block shown above a Think-mode answer.
class ReasoningBlock extends StatefulWidget {
  final String text;
  final bool thinking;
  const ReasoningBlock({super.key, required this.text, required this.thinking});

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    final expanded = _open || widget.thinking;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  if (widget.thinking)
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                    )
                  else
                    Icon(Icons.psychology_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.thinking ? 'Thinking…' : 'Thought process',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                widget.text,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Live card for a [Plan]: shows every step with its status and, while the
/// plan awaits approval, lets the user edit it and start it.
class PlanCard extends StatelessWidget {
  final Plan plan;
  final VoidCallback? onApprove;
  final VoidCallback? onDiscard;
  final void Function(PlanStep step)? onEditStep;
  final void Function(PlanStep step)? onRemoveStep;
  final VoidCallback? onSaveSkill;

  const PlanCard({
    super.key,
    required this.plan,
    this.onApprove,
    this.onDiscard,
    this.onEditStep,
    this.onRemoveStep,
    this.onSaveSkill,
  });

  Color _stateColor(PlanState s) {
    switch (s) {
      case PlanState.done:
        return Colors.green;
      case PlanState.failed:
        return Colors.redAccent;
      case PlanState.cancelled:
      case PlanState.discarded:
        return Colors.orange;
      case PlanState.running:
        return Colors.blue;
      case PlanState.proposed:
        return Colors.indigo;
    }
  }

  String _stateLabel(Plan p) {
    switch (p.state) {
      case PlanState.proposed:
        return p.mode == 'plan' ? 'PLAN ONLY' : 'AWAITING APPROVAL';
      case PlanState.running:
        return 'RUNNING ${p.doneCount}/${p.steps.length}';
      case PlanState.done:
        return 'DONE';
      case PlanState.failed:
        return 'FAILED';
      case PlanState.cancelled:
        return 'STOPPED';
      case PlanState.discarded:
        return 'DISCARDED';
    }
  }

  Widget _stepIcon(PlanStep s, ColorScheme scheme) {
    switch (s.status) {
      case StepStatus.done:
        return const Icon(Icons.check_circle_rounded, size: 20, color: Colors.green);
      case StepStatus.failed:
        return const Icon(Icons.cancel_rounded, size: 20, color: Colors.redAccent);
      case StepStatus.skipped:
        return Icon(Icons.remove_circle_outline_rounded, size: 20, color: Colors.orange.shade700);
      case StepStatus.running:
        return SizedBox(
          width: 18,
          height: 18,
          child: Padding(
            padding: const EdgeInsets.all(1),
            child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary),
          ),
        );
      case StepStatus.pending:
        return Icon(
          Icons.radio_button_unchecked_rounded,
          size: 20,
          color: scheme.onSurface.withValues(alpha: 0.35),
        );
    }
  }

  String _kindLabel(PlanStep s) {
    switch (s.kind) {
      case 'action':
        return 'ACTION';
      case 'respond':
        return 'ANSWER';
      default:
        return 'ON SCREEN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _stateColor(plan.state);
    final editable = plan.awaitingApproval;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan.summary.isEmpty ? plan.goal : plan.summary,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _stateLabel(plan),
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 10),
          for (final step in plan.steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 1), child: _stepIcon(step, scheme)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap: editable && onEditStep != null ? () => onEditStep!(step) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            step.title,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: step.status == StepStatus.running
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text(
                                _kindLabel(step),
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                  color: scheme.onSurface.withValues(alpha: 0.45),
                                ),
                              ),
                              if (step.sensitive) ...[
                                const SizedBox(width: 6),
                                Icon(Icons.shield_outlined, size: 11, color: Colors.orange.shade700),
                                const SizedBox(width: 2),
                                Text(
                                  'ASKS FIRST',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ],
                              if (step.attempts > 1) ...[
                                const SizedBox(width: 6),
                                Text(
                                  'ATTEMPT ${step.attempts}',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                    color: scheme.onSurface.withValues(alpha: 0.45),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (step.result.isNotEmpty &&
                              (step.status == StepStatus.failed || step.kind != 'respond'))
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                step.result,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: step.status == StepStatus.failed
                                      ? Colors.redAccent
                                      : scheme.onSurface.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (editable && onRemoveStep != null && plan.steps.length > 1)
                    InkWell(
                      onTap: () => onRemoveStep!(step),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: scheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (editable) ...[
            const SizedBox(height: 4),
            Text(
              'Tap a step to edit it, or remove steps you do not want.',
              style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDiscard,
                    child: const Text('Discard'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(plan.mode == 'plan' ? 'Run this plan' : 'Approve & run'),
                  ),
                ),
              ],
            ),
          ],
          if (plan.state == PlanState.done && onSaveSkill != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onSaveSkill,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Save as skill'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
