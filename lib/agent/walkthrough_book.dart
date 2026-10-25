import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_skill.dart';

/// A short, human-readable walkthrough of a task that worked — created
/// automatically after a successful phone task, shown in the app, and given
/// to the AI as a guide the next time a similar task on that app comes up.
class Walkthrough {
  final String id;
  final String app;
  final String goal;
  final List<String> steps;
  final int at;
  const Walkthrough({required this.id, required this.app, required this.goal, required this.steps, required this.at});

  Map<String, dynamic> toJson() => {'id': id, 'app': app, 'goal': goal, 'steps': steps, 'at': at};
  static Walkthrough fromJson(Map<String, dynamic> j) => Walkthrough(
        id: (j['id'] ?? '').toString(),
        app: (j['app'] ?? '').toString(),
        goal: (j['goal'] ?? '').toString(),
        steps: ((j['steps'] as List?) ?? const []).map((e) => e.toString()).toList(),
        at: (j['at'] as num?)?.toInt() ?? 0,
      );
}

class WalkthroughBook extends ChangeNotifier {
  WalkthroughBook._();
  static final WalkthroughBook instance = WalkthroughBook._();
  static const _k = 'walkthroughs_v1';
  static const _max = 40;

  List<Walkthrough> _items = [];
  bool _loaded = false;
  List<Walkthrough> get items => List.unmodifiable(_items);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_k);
      if (raw != null && raw.isNotEmpty) {
        _items = (jsonDecode(raw) as List).whereType<Map>().map((m) => Walkthrough.fromJson(Map<String, dynamic>.from(m))).toList();
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance()).setString(_k, jsonEncode(_items.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await load();
    _items.removeWhere((e) => e.id == id);
    await _save();
  }

  /// Turns the steps of a successful run into a walkthrough and stores it.
  Future<void> recordFrom(String goal, List<ActionStep> steps) async {
    final lines = describe(steps);
    if (lines.length < 2 || goal.trim().isEmpty) return;
    await load();
    var app = 'Phone';
    for (final s in steps) {
      if (s.action == 'open_app') {
        final n = (s.params['app_name'] ?? '').toString().trim();
        if (n.isNotEmpty) {
          app = n;
          break;
        }
      }
    }
    final key = goal.trim().toLowerCase();
    _items.removeWhere((e) => e.goal.trim().toLowerCase() == key);
    _items.insert(
      0,
      Walkthrough(id: DateTime.now().microsecondsSinceEpoch.toString(), app: app, goal: goal.trim(), steps: lines, at: DateTime.now().millisecondsSinceEpoch),
    );
    if (_items.length > _max) _items.removeRange(_max, _items.length);
    await _save();
  }

  /// Plain-language steps. Typed text is not stored (it is often personal).
  static List<String> describe(List<ActionStep> steps) {
    final out = <String>[];
    String? last;
    for (final s in steps) {
      final p = s.params;
      String? line;
      switch (s.action) {
        case 'open_app':
          line = 'Open ${p['app_name'] ?? 'the app'}';
        case 'click_text':
          line = 'Tap "${p['text'] ?? ''}"';
        case 'click_at':
          line = 'Tap the highlighted spot on the screen';
        case 'type_text':
          final hint = (p['field_hint'] ?? '').toString().trim();
          line = hint.isEmpty ? 'Type the text' : 'Type the text in the $hint field';
        case 'press_enter':
          line = 'Press Enter / Search';
        case 'scroll':
          line = 'Scroll ${p['direction'] ?? 'down'}';
        case 'press_back':
          line = 'Go back';
        case 'press_home':
          line = 'Go to the home screen';
        default:
          line = null; // wait, done, internal steps
      }
      if (line == null || line == last) continue;
      out.add(line);
      last = line;
    }
    return out.length > 25 ? out.sublist(0, 25) : out;
  }

  /// Walkthroughs worth showing the AI for [goal] (same app mentioned, or a
  /// very similar task). Empty when nothing fits.
  String promptFor(String goal) {
    final g = goal.toLowerCase();
    if (g.isEmpty || _items.isEmpty) return '';
    final words = g.split(RegExp(r'\W+')).where((w) => w.length > 3).toSet();
    final hits = <Walkthrough>[];
    for (final w in _items) {
      final appHit = w.app.length > 2 && g.contains(w.app.toLowerCase());
      final ww = w.goal.toLowerCase().split(RegExp(r'\W+')).where((x) => x.length > 3).toSet();
      final overlap = ww.isEmpty ? 0.0 : ww.intersection(words).length / ww.length;
      if (appHit || overlap >= 0.6) hits.add(w);
      if (hits.length == 2) break;
    }
    if (hits.isEmpty) return '';
    final b = StringBuffer('\nWALKTHROUGHS FROM EARLIER SUCCESSFUL TASKS (a guide only — the screen may differ, always follow what is actually shown):\n');
    for (final w in hits) {
      b.writeln('[${w.app}] ${w.goal}');
      for (var i = 0; i < w.steps.length; i++) {
        b.writeln('  ${i + 1}. ${w.steps[i]}');
      }
    }
    return b.toString();
  }
}
