import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../agent/memory_service.dart';
import '../widgets/screen_helpers.dart';

/// Shows what the agent remembers (memory.md) and lets the user edit it.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final MemoryService _memory = MemoryService.instance;
  Map<String, List<String>> _entries = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await _memory.load(force: true);
    final e = await _memory.entries();
    if (!mounted) return;
    setState(() {
      _entries = e;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    var section = MemoryService.sections[2];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add to memory'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: section,
                items: [
                  for (final s in MemoryService.sections)
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) => setLocal(() => section = v ?? section),
                decoration: const InputDecoration(labelText: 'Section'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'What should I remember?',
                  hintText: 'e.g. Prefers replies in Spanish',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true) {
      final result = await _memory.addFact(section, controller.text);
      if (!mounted) return;
      if (result == MemoryAddResult.sensitive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That looks like a secret. Save it in Accounts instead.'),
          ),
        );
      }
      await _reload();
    }
  }

  Future<void> _remove(String entry) async {
    await _memory.removeMatching(entry);
    await _reload();
  }

  Future<void> _editRaw() async {
    final raw = await _memory.readRaw();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _MemoryEditor(initial: raw)),
    );
    await _reload();
  }

  Future<void> _reset() async {
    final ok = await confirmDialog(
      context,
      title: 'Erase memory?',
      message: 'This deletes everything the agent remembers about you.',
      confirmLabel: 'Erase',
    );
    if (ok) {
      await _memory.reset();
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _entries.values.fold<int>(0, (a, b) => a + b.length);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            tooltip: 'Copy memory.md',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              final raw = await _memory.readRaw();
              await Clipboard.setData(ClipboardData(text: raw));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('memory.md copied')),
              );
            },
          ),
          IconButton(tooltip: 'Edit as markdown', icon: const Icon(Icons.edit_note_rounded), onPressed: _editRaw),
          IconButton(tooltip: 'Erase', icon: const Icon(Icons.delete_outline_rounded), onPressed: total == 0 ? null : _reset),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                const InfoBanner(
                  icon: Icons.lock_outline_rounded,
                  text:
                      'Stored only on this phone in memory.md. Relevant parts are sent to your AI provider with your requests so the agent can personalise answers. Never put passwords here; use Accounts.',
                ),
                if (total == 0)
                  const SizedBox(
                    height: 380,
                    child: EmptyState(
                      icon: Icons.psychology_alt_outlined,
                      title: 'Nothing remembered yet',
                      subtitle:
                          'Say "remember that I prefer dark mode", or just talk: the agent learns durable facts about you as you go.',
                    ),
                  ),
                for (final section in _entries.keys)
                  if (_entries[section]!.isNotEmpty) ...[
                    SectionLabel(section),
                    for (final entry in _entries[section]!)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.07)),
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text(entry, style: const TextStyle(fontSize: 13.5, height: 1.35))),
                            IconButton(
                              icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurface.withValues(alpha: 0.45)),
                              onPressed: () => _remove(entry),
                            ),
                          ],
                        ),
                      ),
                  ],
              ],
            ),
    );
  }
}

class _MemoryEditor extends StatefulWidget {
  final String initial;
  const _MemoryEditor({required this.initial});

  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('memory.md'),
        actions: [
          TextButton(
            onPressed: () async {
              await MemoryService.instance.writeRaw(_controller.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '# PrivateAgent Memory'),
        ),
      ),
    );
  }
}
