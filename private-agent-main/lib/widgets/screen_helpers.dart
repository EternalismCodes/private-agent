import 'package:flutter/material.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const EmptyState({super.key, required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.1),
              ),
              child: Icon(icon, size: 34, color: scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final Widget? action;
  const InfoBanner({super.key, required this.icon, required this.text, this.color, this.action});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4))),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel, style: const TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  return result == true;
}
