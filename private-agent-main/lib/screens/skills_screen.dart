import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../agent/skills_service.dart';
import '../models/saved_skill.dart';
import '../services/skill_memory_service.dart';
import '../widgets/screen_helpers.dart';

/// Reusable Skills (instructions) and automatically learned workflows.
/// Pops with a prompt string when the user taps "Run".
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  final SkillsService _skills = SkillsService.instance;
  final SkillMemoryService _workflows = SkillMemoryService();
  List<AgentSkill> _items = [];
  List<SavedSkill> _learned = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await _skills.load(force: true);
    final learned = await _workflows.listAll();
    if (!mounted) return;
    setState(() {
      _items = List<AgentSkill>.from(_skills.items);
      _learned = learned;
      _loading = false;
    });
  }

  Future<void> _edit([AgentSkill? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final description = TextEditingController(text: existing?.description ?? '');
    final triggers = TextEditingController(text: existing?.triggers.join(', ') ?? '');
    final instructions = TextEditingController(text: existing?.instructions ?? '');
    final formKey = GlobalKey<FormState>();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'New skill' : 'Edit skill',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Give it a name' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'What it does (one line)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: triggers,
                  decoration: const InputDecoration(
                    labelText: 'Trigger phrases (comma separated)',
                    hintText: 'order coffee, morning coffee',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: instructions,
                  minLines: 5,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: 'Instructions',
                    hintText: '1. Open the Starbucks app\n2. Reorder my usual\n3. Pay with the saved card',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Write the steps' : null,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
                    },
                    child: const Text('Save skill'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (saved == true) {
      final skill = existing ??
          AgentSkill(id: SkillsService.newId(), name: '', instructions: '');
      skill.name = name.text.trim();
      skill.description = description.text.trim();
      skill.triggers = triggers.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      skill.instructions = instructions.text.trim();
      await _skills.save(skill);
      await _reload();
    }
  }

  Future<void> _delete(AgentSkill skill) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete skill?',
      message: '"${skill.name}" will be removed.',
    );
    if (ok) {
      await _skills.delete(skill.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Skills & workflows'),
          bottom: const TabBar(tabs: [Tab(text: 'Skills'), Tab(text: 'Learned workflows')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('New skill'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _items.isEmpty
                      ? const EmptyState(
                          icon: Icons.extension_outlined,
                          title: 'No skills yet',
                          subtitle:
                              'A skill is a reusable recipe, like "order my usual coffee". The agent follows matching skills automatically, or you can run one on demand.',
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          children: [for (final s in _items) _skillTile(s, scheme)],
                        ),
                  _learned.isEmpty
                      ? const EmptyState(
                          icon: Icons.auto_fix_high_outlined,
                          title: 'Nothing learned yet',
                          subtitle:
                              'When the agent completes a task on screen it remembers the exact taps, so the same task can be replayed instantly next time.',
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                          children: [for (final w in _learned) _workflowTile(w, scheme)],
                        ),
                ],
              ),
      ),
    );
  }

  Widget _skillTile(AgentSkill s, ColorScheme scheme) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(s.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Switch(
                  value: s.enabled,
                  onChanged: (v) async {
                    s.enabled = v;
                    await _skills.save(s);
                    await _reload();
                  },
                ),
              ],
            ),
            if (s.description.isNotEmpty)
              Text(s.description, style: TextStyle(fontSize: 12.5, color: scheme.onSurface.withValues(alpha: 0.65))),
            const SizedBox(height: 6),
            Text(
              s.instructions,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _chip(s.source == 'agent' ? 'Learned by agent' : (s.source == 'builtin' ? 'Starter' : 'Yours'), scheme),
                const SizedBox(width: 6),
                _chip('Used ${s.useCount}×', scheme),
                const Spacer(),
                IconButton(
                  tooltip: 'Run',
                  icon: Icon(Icons.play_circle_outline_rounded, color: scheme.primary),
                  onPressed: s.enabled ? () => Navigator.pop(context, 'Run my skill "${s.name}"') : null,
                ),
                IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _edit(s)),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: () => _delete(s),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
      );

  Widget _workflowTile(SavedSkill w, ColorScheme scheme) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        title: Text(w.task, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(
          '${w.steps.length} steps · ${w.successCount} successes · ${w.failCount} failures\nLast used ${DateFormat('MMM d, HH:mm').format(w.lastUsed)}',
          style: const TextStyle(fontSize: 12, height: 1.4),
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () async {
            await _workflows.deleteSkill(w.id);
            await _reload();
          },
        ),
      ),
    );
  }
}
