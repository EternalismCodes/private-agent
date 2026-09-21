import 'package:flutter/material.dart';
import '../agent/vault_service.dart';
import '../widgets/screen_helpers.dart';

/// Encrypted accounts the agent can log in with. The agent never sees the
/// passwords: the app types them into the field locally.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final VaultService _vault = VaultService.instance;
  List<Credential> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await _vault.load(force: true);
    if (!mounted) return;
    setState(() {
      _items = List<Credential>.from(_vault.items);
      _loading = false;
    });
  }

  Future<void> _edit([Credential? existing]) async {
    final label = TextEditingController(text: existing?.label ?? '');
    final username = TextEditingController(text: existing?.username ?? '');
    final password = TextEditingController(text: existing?.password ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final notes = TextEditingController(text: existing?.notes ?? '');
    final formKey = GlobalKey<FormState>();
    var hidden = true;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(existing == null ? 'New account' : 'Edit account',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: label,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'Netflix, Work Gmail...',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Give it a label' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: username,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Username or email', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: password,
                    obscureText: hidden,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                        onPressed: () => setLocal(() => hidden = !hidden),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: url,
                    decoration: const InputDecoration(labelText: 'App or website (optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: notes,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (saved == true) {
      final c = existing ?? Credential(id: VaultService.newId(), label: '');
      c.label = label.text.trim();
      c.username = username.text.trim();
      c.password = password.text;
      c.url = url.text.trim();
      c.notes = notes.text.trim();
      await _vault.save(c);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = _vault.usingFallback;
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add account'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                InfoBanner(
                  icon: fallback ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
                  color: fallback ? Colors.orange : Colors.green,
                  text: fallback
                      ? 'Android Keystore is not available on this device, so accounts are kept in a private file inside the app. Other apps cannot read it, but it is not hardware-encrypted.'
                      : 'Encrypted with the Android Keystore. The agent only sees the account label; passwords are typed into apps locally and never sent to your AI provider.',
                ),
                if (_items.isEmpty)
                  const SizedBox(
                    height: 380,
                    child: EmptyState(
                      icon: Icons.key_rounded,
                      title: 'No accounts saved',
                      subtitle: 'Add a login and the agent can sign in to apps for you when a task needs it.',
                    ),
                  ),
                for (final c in _items)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primary.withValues(alpha: 0.12),
                        child: Text(
                          c.label.isEmpty ? '?' : c.label[0].toUpperCase(),
                          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800),
                        ),
                      ),
                      title: Text(c.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        c.username.isEmpty ? '••••••••' : '${c.username}  ·  ••••••••',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      onTap: () => _edit(c),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'Delete account?',
                            message: '"${c.label}" will be removed from this phone.',
                          );
                          if (ok) {
                            await _vault.delete(c.id);
                            await _reload();
                          }
                        },
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
