import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/app_launcher_service.dart';
import '../services/screen_automation_service.dart';
import 'lab_channel.dart';
import 'lab_prefs.dart';
import 'lab_vision.dart';
import 'teach.dart';

/// Teach & experiments hub. Everything here is experimental and off by default.
class LabScreen extends StatefulWidget {
  final ScreenAutomationService screen;
  final AppLauncherService launcher;
  final AiService ai;
  const LabScreen({super.key, required this.screen, required this.launcher, required this.ai});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> with WidgetsBindingObserver {
  final _prefs = LabPrefs.instance;
  final _teach = LabTeach.instance;
  final _model = TextEditingController();
  final _base = TextEditingController();
  final _key = TextEditingController();
  bool _ready = false;
  bool _recording = false;
  bool _testing = false;
  Map<String, String> _meta = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _teach.ensureLoaded();
    _model.text = _prefs.vlmModel;
    _base.text = _prefs.vlmBaseUrl;
    _key.text = _prefs.vlmKey;
    LabChannel.onStopped = _onStopped;
    _recording = await LabChannel.recActive();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (LabChannel.onStopped == _onStopped) LabChannel.onStopped = null;
    _model.dispose();
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed && _recording) {
      final active = await LabChannel.recActive();
      if (!active && mounted && _recording) _openReview(await LabChannel.recStop());
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _savePrefs() async {
    _prefs.vlmModel = _model.text;
    _prefs.vlmBaseUrl = _base.text;
    _prefs.vlmKey = _key.text;
    await _prefs.save();
  }

  void _onStopped(String json) {
    if (mounted && _recording) _openReview(json);
  }

  Future<dynamic> _pickApp() async {
    final List<dynamic> apps = List<dynamic>.from(await widget.launcher.getInstalledApps());
    apps.sort((a, b) => '${a.name}'.toLowerCase().compareTo('${b.name}'.toLowerCase()));
    if (!mounted) return null;
    var q = '';
    return showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final shown = apps.where((a) => q.isEmpty || '${a.name}'.toLowerCase().contains(q) || '${a.packageName}'.toLowerCase().contains(q)).toList();
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search apps', border: OutlineInputBorder()),
                  onChanged: (v) => set(() => q = v.toLowerCase().trim()),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text('${shown[i].name}'),
                    subtitle: Text('${shown[i].packageName}', style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, shown[i]),
                  ),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _startTeach() async {
    if (!_prefs.teach) {
      _snack('Turn on "Teach tasks" first.');
      return;
    }
    if (!await widget.screen.isServiceRunning()) {
      _snack('Enable the PrivateAgent accessibility service first.');
      return;
    }
    final name = TextEditingController();
    final desc = TextEditingController();
    dynamic app;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Teach a task'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Task name', hintText: 'WhatsApp search and send'),
              ),
              TextField(
                controller: desc,
                decoration: const InputDecoration(labelText: 'What it does (helps the model pick it)'),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.apps_rounded),
                title: Text(app == null ? 'Choose the app to record' : '${app.name}'),
                onTap: () async {
                  final a = await _pickApp();
                  if (a != null) set(() => app = a);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: (name.text.trim().isEmpty || app == null) ? null : () => Navigator.pop(ctx, true),
              child: const Text('Start recording'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || app == null) return;
    _meta = {'name': name.text.trim(), 'desc': desc.text.trim(), 'pkg': '${app.packageName}', 'app': '${app.name}'};
    if (!await LabChannel.recStart(_meta['pkg']!)) {
      _snack('Could not start recording.');
      return;
    }
    setState(() => _recording = true);
    await widget.launcher.openPackage(_meta['pkg']!);
  }

  Future<void> _openReview(String json) async {
    if (!_recording) return;
    setState(() => _recording = false);
    List<dynamic> raw;
    try {
      raw = jsonDecode(json) as List;
    } catch (_) {
      raw = [];
    }
    final steps = raw.whereType<Map>().map((m) => TeachStep(Map<String, dynamic>.from(m))).toList();
    if (steps.isEmpty) {
      _snack('Nothing was recorded.');
      return;
    }
    final task = TaughtTask.draft(
      name: _meta['name'] ?? 'Taught task',
      description: _meta['desc'] ?? '',
      pkg: _meta['pkg'] ?? '${steps.first.d['pkg']}',
      appName: _meta['app'] ?? '',
      steps: steps,
    );
    if (!mounted) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => TeachReviewScreen(task: task)));
    if (saved == true && mounted) setState(() {});
  }

  Future<void> _runTest(TaughtTask t) async {
    final vars = t.variables;
    final ctrls = {for (final v in vars) v: TextEditingController()};
    if (vars.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Run "${t.name}"'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final v in vars) TextField(controller: ctrls[v], decoration: InputDecoration(labelText: v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _snack('Running…');
    final r = await _teach.run(
      t.slug,
      {for (final v in vars) v: ctrls[v]!.text},
      screen: widget.screen,
      launcher: widget.launcher,
    );
    _snack(r);
  }

  Future<void> _testVision() async {
    await _savePrefs();
    setState(() => _testing = true);
    final r = await LabVision.instance.analyze(
      'Describe this screen in one short sentence.',
      screen: widget.screen,
      launcher: widget.launcher,
      ai: widget.ai,
    );
    if (!mounted) return;
    setState(() => _testing = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vision test'),
        content: Text(r),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(appBar: AppBar(title: const Text('Teach & experiments')), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Teach & experiments')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Experimental. Both features are off by default; if they misbehave, switch them off and the rest of the app is unaffected.',
              style: TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
          if (_recording)
            Card(
              margin: const EdgeInsets.all(12),
              child: ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: Colors.red),
                title: const Text('Recording in progress'),
                subtitle: const Text('Do the task in the app, then tap Stop on the floating pill (or here).'),
                trailing: TextButton(
                  onPressed: () async => _openReview(await LabChannel.recStop()),
                  child: const Text('Finish'),
                ),
              ),
            ),
          const Divider(),
          SwitchListTile(
            title: const Text('Vision fallback (VLM)', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('When the agent is stuck, or you ask it to look at / analyse the screen, it takes a screenshot and asks a vision model.'),
            value: _prefs.vision,
            onChanged: (v) async {
              setState(() => _prefs.vision = v);
              await _savePrefs();
            },
          ),
          if (_prefs.vision)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                TextField(
                  controller: _model,
                  onChanged: (_) => _savePrefs(),
                  decoration: const InputDecoration(labelText: 'Vision model', hintText: 'e.g. meta/llama-3.2-11b-vision-instruct', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _base,
                  onChanged: (_) => _savePrefs(),
                  decoration: const InputDecoration(labelText: 'Base URL (blank = your main provider)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _key,
                  obscureText: true,
                  onChanged: (_) => _savePrefs(),
                  decoration: const InputDecoration(labelText: 'API key (blank = your main key)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testVision,
                    icon: const Icon(Icons.image_search_rounded),
                    label: Text(_testing ? 'Testing…' : 'Test vision on my screen'),
                  ),
                ),
              ]),
            ),
          const Divider(),
          SwitchListTile(
            title: const Text('Teach tasks', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Record a task once in any app, mark what changes as variables, and the agent replays it on request.'),
            value: _prefs.teach,
            onChanged: (v) async {
              setState(() => _prefs.teach = v);
              await _savePrefs();
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _recording ? null : _startTeach,
                icon: const Icon(Icons.school_outlined),
                label: const Text('Teach a task'),
              ),
            ),
          ),
          for (final t in _teach.tasks)
            ListTile(
              leading: const Icon(Icons.play_lesson_outlined),
              title: Text(t.name),
              subtitle: Text('${t.appName} · ${t.variables.isEmpty ? 'no variables' : t.variables.join(', ')} · ${t.steps.length} steps'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Test run', onPressed: () => _runTest(t)),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () async {
                    await _teach.remove(t);
                    if (mounted) setState(() {});
                  },
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

/// Review a fresh recording: pick variables, bind taps, add/remove steps.
class TeachReviewScreen extends StatefulWidget {
  final TaughtTask task;
  const TeachReviewScreen({super.key, required this.task});

  @override
  State<TeachReviewScreen> createState() => _TeachReviewScreenState();
}

class _TeachReviewScreenState extends State<TeachReviewScreen> {
  late final TextEditingController _name = TextEditingController(text: widget.task.name);
  late List<TeachStep> _steps = List<TeachStep>.from(widget.task.steps);

  List<String> _varNames() {
    final out = <String>[];
    for (final s in _steps) {
      if (s.type == 'type' && s.varName.isNotEmpty && !out.contains(s.varName)) out.add(s.varName);
    }
    return out;
  }

  void _menu(int i, String v) {
    setState(() {
      if (v == 'del') {
        _steps.removeAt(i);
      } else if (v == 'enter') {
        _steps.insert(i + 1, TeachStep({'t': 'enter', 'dt': 500}));
      } else if (v == 'back') {
        _steps.insert(i + 1, TeachStep({'t': 'back', 'dt': 500}));
      } else if (v == 'wait') {
        _steps.insert(i + 1, TeachStep({'t': 'wait', 'ms': 2000}));
      }
    });
  }

  Widget _row(int i) {
    final s = _steps[i];
    final vars = _varNames();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 11))),
            const SizedBox(width: 8),
            Expanded(child: Text(s.describe(), style: const TextStyle(fontWeight: FontWeight.w600))),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(i, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'del', child: Text('Delete step')),
                PopupMenuItem(value: 'enter', child: Text('Add "Press Enter" after')),
                PopupMenuItem(value: 'back', child: Text('Add "Back" after')),
                PopupMenuItem(value: 'wait', child: Text('Add "Wait 2s" after')),
              ],
            ),
          ]),
          if (s.type == 'type')
            Row(children: [
              const Text('Variable'),
              Switch(
                value: s.isVar,
                onChanged: (v) => setState(() => s.d['var'] = v ? 'value${i + 1}' : ''),
              ),
              if (s.isVar)
                Expanded(
                  child: TextFormField(
                    key: ValueKey('v${s.hashCode}'),
                    initialValue: s.varName,
                    decoration: const InputDecoration(isDense: true, labelText: 'name (e.g. message)'),
                    onChanged: (v) => s.d['var'] = v.trim(),
                  ),
                ),
            ]),
          if (s.type == 'click' && vars.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: vars.contains(s.bind) ? s.bind : '',
              items: [
                const DropdownMenuItem(value: '', child: Text('Tap the recorded target')),
                for (final v in vars) DropdownMenuItem(value: v, child: Text('Tap item matching {$v}')),
              ],
              onChanged: (v) => setState(() => s.d['bind'] = v ?? ''),
            ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    final ok = RegExp(r'^[a-z][a-z0-9_]*$');
    for (final n in _varNames()) {
      if (!ok.hasMatch(n)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Variable names: lowercase letters, digits, underscore (e.g. contact).')));
        return;
      }
    }
    if (_name.text.trim().isNotEmpty) widget.task.name = _name.text.trim();
    widget.task.steps = _steps;
    await LabTeach.instance.add(widget.task);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review recording')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Task name', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const Text(
            'Typed text is a variable by default (value1, value2 …): rename it (contact, message …) or switch it off to keep the recorded text. A tap on something you typed is bound to that variable. Add Enter/Back/Wait via the ⋮ menu (Enter is not recorded automatically).',
            style: TextStyle(fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _steps.length; i++) _row(i),
        ],
      ),
    );
  }
}
