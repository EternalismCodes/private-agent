import 'package:flutter/material.dart';
import '../agent/people_book.dart';
import '../agent/walkthrough_book.dart';

/// Aliases for people (and the app used to reach them) plus the walkthroughs
/// the agent wrote after successful tasks.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final PeopleBook _people = PeopleBook.instance;
  final WalkthroughBook _walks = WalkthroughBook.instance;

  @override
  void initState() {
    super.initState();
    _people.addListener(_changed);
    _walks.addListener(_changed);
    Future.wait([_people.load(), _walks.load()]).then((_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _people.removeListener(_changed);
    _walks.removeListener(_changed);
    super.dispose();
  }

  Future<void> _edit([Person? existing]) async {
    final aliases = TextEditingController(text: existing?.aliases.join(', ') ?? '');
    final contact = TextEditingController(text: existing?.contact ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final relation = TextEditingController(text: existing?.relation ?? '');
    final via = TextEditingController(text: existing?.via ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Add person' : 'Edit person'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: aliases, decoration: const InputDecoration(labelText: 'Aliases', helperText: 'What you call them, separated by commas: mom, mummy')),
                TextField(controller: contact, decoration: const InputDecoration(labelText: 'Name in your contacts')),
                TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number (optional)')),
                TextField(controller: relation, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'my mother, my boss…')),
                TextField(controller: via, decoration: const InputDecoration(labelText: 'Usually reached via', hintText: 'WhatsApp, Phone call, SMS…')),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final a in const ['WhatsApp', 'Phone call', 'SMS', 'Telegram', 'Instagram'])
                      ActionChip(label: Text(a), onPressed: () => setLocal(() => via.text = a)),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final list = aliases.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (list.isEmpty && contact.text.trim().isEmpty) return;
    await _people.upsert(Person(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      aliases: list,
      contact: contact.text.trim(),
      phone: phone.text.trim(),
      relation: relation.text.trim(),
      via: via.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('People & walkthroughs'),
          bottom: const TabBar(tabs: [Tab(text: 'People'), Tab(text: 'Walkthroughs')]),
        ),
        body: TabBarView(children: [_peopleTab(), _walkTab()]),
      ),
    );
  }

  Widget _peopleTab() {
    final list = _people.people;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            const Text(
              'Give people nicknames so "call mom" or "message my boss" always means the right person. You can also say which app you use for them; the agent learns your habits over time too.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey, height: 1.35),
            ),
            const SizedBox(height: 8),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No people yet'))),
            for (final p in list)
              Card(
                child: ListTile(
                  title: Text(p.aliases.isEmpty ? p.contact : p.aliases.join(', ')),
                  subtitle: Text([
                    if (p.contact.isNotEmpty) p.contact,
                    if (p.phone.isNotEmpty) p.phone,
                    if (p.relation.isNotEmpty) p.relation,
                    if (p.via.isNotEmpty) 'via ${p.via}',
                  ].join(' • ')),
                  onTap: () => _edit(p),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _people.remove(p.id)),
                ),
              ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('Add person')),
        ),
      ],
    );
  }

  Widget _walkTab() {
    final list = _walks.items;
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('After a phone task succeeds, a short walkthrough of it appears here and is used as a guide the next time.', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final w in list)
          Card(
            child: ExpansionTile(
              title: Text(w.goal, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${w.app} • ${w.steps.length} steps'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < w.steps.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${i + 1}. ${w.steps[i]}')),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(onPressed: () => _walks.remove(w.id), icon: const Icon(Icons.delete_outline_rounded, size: 18), label: const Text('Delete')),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
