import 'package:flutter/material.dart';
import '../services/ai_service.dart';

/// Lets the user add extra OpenAI-compatible providers. When the main
/// provider fails, requests automatically move to the next one and keep
/// cycling; with no backups, the single provider is retried up to 4 times.
class BackupProvidersCard extends StatefulWidget {
  final AiService aiService;
  const BackupProvidersCard({super.key, required this.aiService});

  @override
  State<BackupProvidersCard> createState() => _BackupProvidersCardState();
}

class _BackupProvidersCardState extends State<BackupProvidersCard> {
  late List<ProviderConfig> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.aiService.backupProviders);
  }

  Future<void> _persist() async {
    await widget.aiService.saveBackupProviders(_items);
    if (mounted) setState(() {});
  }

  Future<void> _edit({int? index}) async {
    final existing = index == null ? null : _items[index];
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.baseUrl ?? '');
    final key = TextEditingController(text: existing?.apiKey ?? '');
    final model = TextEditingController(text: existing?.model ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add backup provider' : 'Edit backup provider'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. NVIDIA)')),
              TextField(controller: url, decoration: const InputDecoration(labelText: 'Base URL', hintText: 'https://api.deepseek.com')),
              TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
              TextField(controller: model, decoration: const InputDecoration(labelText: 'Model', hintText: 'deepseek-chat')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    var k = key.text.trim();
    if (k.toLowerCase().startsWith('bearer ')) k = k.substring(7).trim();
    final item = ProviderConfig(
      name: name.text.trim(),
      baseUrl: url.text.trim(),
      apiKey: k,
      model: model.text.trim(),
      enabled: existing?.enabled ?? true,
    );
    if (index == null) {
      _items.add(item);
    } else {
      _items[index] = item;
    }
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.swap_horiz_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Backup providers', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 6),
            const Text(
              'If the main provider fails, requests move to these automatically and keep cycling through them. With no backups, the main provider is retried up to 4 times before the task ends.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey, height: 1.35),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _items.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_items[i].name.isEmpty ? _items[i].baseUrl : _items[i].name),
                subtitle: Text('${_items[i].model} • ${_items[i].usable ? 'ready' : 'incomplete'}', style: const TextStyle(fontSize: 12)),
                onTap: () => _edit(index: i),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                    value: _items[i].enabled,
                    onChanged: (v) {
                      final o = _items[i];
                      _items[i] = ProviderConfig(name: o.name, baseUrl: o.baseUrl, apiKey: o.apiKey, model: o.model, enabled: v);
                      _persist();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () {
                      _items.removeAt(i);
                      _persist();
                    },
                  ),
                ]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add backup provider'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
