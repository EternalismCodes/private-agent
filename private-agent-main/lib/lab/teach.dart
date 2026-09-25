import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../agent/safe_cast.dart';
import '../services/app_launcher_service.dart';
import '../services/screen_automation_service.dart';
import 'lab_channel.dart';
import 'lab_prefs.dart';

/// One recorded action. [d] holds what the native recorder captured plus the
/// user's choices: 'var' (typed text comes from this variable) and 'bind'
/// (tap the item whose text matches this variable).
class TeachStep {
  final Map<String, dynamic> d;
  TeachStep(this.d);

  String get type => '${d['t'] ?? ''}';
  String get varName => '${d['var'] ?? ''}';
  bool get isVar => varName.isNotEmpty;
  String get bind => '${d['bind'] ?? ''}';
  int get delayMs => asInt(d['dt']) ?? 0;

  String _target() {
    for (final k in ['text', 'desc']) {
      final v = '${d[k] ?? ''}'.trim();
      if (v.isNotEmpty) return v;
    }
    final id = '${d['id'] ?? ''}';
    if (id.isNotEmpty) return id.split('/').last;
    return '${d['cls'] ?? 'element'}'.split('.').last;
  }

  String describe([Map<String, dynamic>? vars]) {
    switch (type) {
      case 'click':
        if (bind.isNotEmpty) return 'Tap item matching {$bind}${vars != null ? ' ("${vars[bind] ?? ''}")' : ''}';
        return 'Tap "${_target()}"';
      case 'type':
        if (isVar) return 'Type {$varName}${vars != null ? ' ("${vars[varName] ?? ''}")' : ''}';
        return 'Type "${d['val'] ?? ''}"';
      case 'scroll':
        return 'Scroll ${d['dir'] ?? 'down'}';
      case 'back':
        return 'Press Back';
      case 'enter':
        return 'Press Enter / Search';
      case 'wait':
        return 'Wait ${((asInt(d['ms']) ?? 2000) / 1000).toStringAsFixed(0)}s';
      default:
        return type;
    }
  }
}

class TaughtTask {
  String id;
  String name;
  String description;
  String pkg;
  String appName;
  List<TeachStep> steps;

  TaughtTask({
    required this.id,
    required this.name,
    required this.description,
    required this.pkg,
    required this.appName,
    required this.steps,
  });

  String get slug {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'task' : s;
  }

  List<String> get variables {
    final out = <String>[];
    for (final s in steps) {
      final v = s.type == 'type' ? s.varName : '';
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    for (final s in steps) {
      if (s.bind.isNotEmpty && !out.contains(s.bind)) out.add(s.bind);
    }
    return out;
  }

  /// New recording: typed texts become variables (value1, value2, ...) and taps
  /// on something you had just typed are bound to that variable.
  factory TaughtTask.draft({
    required String name,
    required String description,
    required String pkg,
    required String appName,
    required List<TeachStep> steps,
  }) {
    var n = 0;
    final typed = <String, String>{};
    for (final s in steps) {
      if (s.type == 'type') {
        n++;
        s.d['var'] = 'value$n';
        final v = '${s.d['val'] ?? ''}'.trim().toLowerCase();
        if (v.isNotEmpty) typed[v] = 'value$n';
      }
    }
    for (final s in steps) {
      if (s.type == 'click') {
        final t = '${s.d['text'] ?? ''}'.trim().toLowerCase();
        if (t.isNotEmpty && typed.containsKey(t)) s.d['bind'] = typed[t];
      }
    }
    return TaughtTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      pkg: pkg,
      appName: appName,
      steps: steps,
    );
  }

  factory TaughtTask.fromJson(Map<String, dynamic> j) => TaughtTask(
        id: '${j['id']}',
        name: '${j['name']}',
        description: '${j['description'] ?? ''}',
        pkg: '${j['pkg']}',
        appName: '${j['app'] ?? ''}',
        steps: (j['steps'] as List).whereType<Map>().map((m) => TeachStep(Map<String, dynamic>.from(m))).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'pkg': pkg,
        'app': appName,
        'steps': steps.map((s) => s.d).toList(),
      };
}

/// EXPERIMENTAL "Teach": record taps/typing once, replay with variables.
class LabTeach {
  LabTeach._();
  static final LabTeach instance = LabTeach._();
  static const String _key = 'lab_taught_v1';

  final List<TaughtTask> tasks = [];
  bool _loaded = false;
  bool _cancel = false;

  void cancel() => _cancel = true;

  Future<void> ensureLoaded() async {
    await LabPrefs.instance.load();
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        for (final e in jsonDecode(raw) as List) {
          try {
            tasks.add(TaughtTask.fromJson(Map<String, dynamic>.from(e as Map)));
          } catch (_) {}
        }
      }
      _loaded = true;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> add(TaughtTask t) async {
    tasks.removeWhere((x) => x.id == t.id || x.slug == t.slug);
    tasks.add(t);
    await _save();
  }

  Future<void> remove(TaughtTask t) async {
    tasks.removeWhere((x) => x.id == t.id);
    await _save();
  }

  TaughtTask? find(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final t in tasks) {
      if (t.slug == n || t.name.toLowerCase() == n) return t;
    }
    for (final t in tasks) {
      if (t.slug.contains(n) || t.name.toLowerCase().contains(n)) return t;
    }
    return null;
  }

  /// Extra system-prompt text listing the taught tasks (empty when off).
  String promptSection() {
    if (!LabPrefs.instance.teach || tasks.isEmpty) return '';
    final b = StringBuffer(
        '\n\nTAUGHT TASKS (experimental, recorded by the user). To use one reply with {"action":"run_taught","params":{"name":"<slug>","vars":{...}}} and fill EVERY variable from the request (ask if one is missing). Prefer these over execute_task when they fit:\n');
    for (final t in tasks) {
      final v = t.variables;
      b.writeln('- ${t.slug}: ${t.description.isEmpty ? t.name : t.description} (app: ${t.appName}; vars: ${v.isEmpty ? 'none' : v.join(', ')})');
    }
    return b.toString();
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  Future<String> run(
    String name,
    Map<String, dynamic> vars, {
    required ScreenAutomationService screen,
    required AppLauncherService launcher,
    void Function(String)? onProgress,
  }) async {
    try {
      await ensureLoaded();
      if (!LabPrefs.instance.teach) return 'Could not run: "Teach tasks" is switched off in Teach & experiments.';
      final t = find(name);
      if (t == null) return 'Could not find a taught task called "$name".';
      final missing = t.variables.where((v) => '${vars[v] ?? ''}'.trim().isEmpty).toList();
      if (missing.isNotEmpty) return 'Could not run "${t.name}": I still need ${missing.join(', ')}.';
      _cancel = false;
      onProgress?.call('Opening ${t.appName.isEmpty ? t.pkg : t.appName}…');
      await launcher.openPackage(t.pkg);
      for (var i = 0; i < 16; i++) {
        if (await screen.getCurrentPackage() == t.pkg) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      for (var i = 0; i < t.steps.length; i++) {
        if (_cancel) return 'Stopped.';
        final s = t.steps[i];
        onProgress?.call('Step ${i + 1}/${t.steps.length}: ${s.describe(vars)}');
        final wait = s.type == 'wait' ? (asInt(s.d['ms']) ?? 2000) : _clamp(s.delayMs, 450, 2500);
        await Future<void>.delayed(Duration(milliseconds: wait));
        var ok = s.type == 'wait';
        for (var a = 0; a < 4 && !ok; a++) {
          if (_cancel) return 'Stopped.';
          switch (s.type) {
            case 'click':
              ok = await LabChannel.replayClick(s.d, s.bind.isEmpty ? null : '${vars[s.bind] ?? ''}');
              break;
            case 'type':
              ok = await LabChannel.replayType(s.d, s.isVar ? '${vars[s.varName] ?? ''}' : '${s.d['val'] ?? ''}');
              break;
            case 'scroll':
              ok = await screen.scroll('${s.d['dir'] ?? 'down'}');
              break;
            case 'back':
              ok = await screen.pressBack();
              break;
            case 'enter':
              ok = await LabChannel.replayEnter() || await screen.pressEnter();
              break;
            default:
              ok = true;
          }
          if (!ok) await Future<void>.delayed(const Duration(milliseconds: 800));
        }
        if (!ok) return 'Could not finish "${t.name}": step ${i + 1} (${s.describe(vars)}) failed.';
      }
      return 'Done: ${t.name}';
    } catch (e) {
      return 'Could not run the taught task: $e';
    }
  }
}
