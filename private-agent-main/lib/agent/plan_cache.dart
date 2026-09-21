import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'json_utils.dart';
import 'plan.dart';

/// A request that was carried out successfully on the phone, remembered as
/// its list of steps. The next time the very same request comes in, the app
/// skips the model calls that decide what to do and goes straight to running
/// the steps (whose on-screen part is replayed from learned workflows).
class CachedRoutine {
  final String key;
  String goal;
  List<Map<String, dynamic>> steps;
  int successCount;
  int failCount;
  DateTime lastUsed;

  CachedRoutine({
    required this.key,
    required this.goal,
    required this.steps,
    this.successCount = 1,
    this.failCount = 0,
    DateTime? lastUsed,
  }) : lastUsed = lastUsed ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'key': key,
        'goal': goal,
        'steps': steps,
        'success_count': successCount,
        'fail_count': failCount,
        'last_used': lastUsed.toIso8601String(),
      };

  factory CachedRoutine.fromJson(Map<String, dynamic> json) => CachedRoutine(
        key: JsonUtils.str(json['key']),
        goal: JsonUtils.str(json['goal']),
        steps: json['steps'] is List
            ? (json['steps'] as List)
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[],
        successCount: json['success_count'] is num ? (json['success_count'] as num).toInt() : 1,
        failCount: json['fail_count'] is num ? (json['fail_count'] as num).toInt() : 0,
        lastUsed: DateTime.tryParse(JsonUtils.str(json['last_used'])),
      );

  /// A fresh plan (all steps pending) built from the saved steps.
  Plan toPlan(String mode) {
    final list = <PlanStep>[];
    for (final m in steps) {
      final step = PlanStep.fromJson(m);
      step.status = StepStatus.pending;
      step.attempts = 0;
      step.result = '';
      list.add(step);
    }
    return Plan(goal: goal, summary: goal, mode: mode, steps: list);
  }
}

class PlanCache {
  PlanCache._();
  static final PlanCache instance = PlanCache._();

  static const Set<String> _filler = {
    'please', 'can', 'could', 'would', 'you', 'hey', 'the', 'a', 'an', 'to', 'for',
    'me', 'now', 'just', 'then', 'and', 'my', 'on', 'in', 'of', 'it', 'is',
  };

  /// Requests containing these depend on the moment, so they are never cached.
  static final RegExp _volatile = RegExp(
    r'\b(latest|newest|unread|recent|current|currently|tonight|tomorrow|yesterday|reply|respond|summarize|summarise|remind|schedule|every)\b',
  );

  /// Order-insensitive fingerprint of a request.
  static String keyOf(String text) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_filler.contains(w))
        .toSet()
        .toList()
      ..sort();
    return words.join(' ');
  }

  final List<CachedRoutine> _items = [];
  bool _loaded = false;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/plan_cache.json');
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _items.clear();
    try {
      final f = await _file();
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) _items.add(CachedRoutine.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_items.map((e) => e.toJson()).toList()), flush: true);
    } catch (_) {}
  }

  Future<List<CachedRoutine>> list() async {
    await load(force: true);
    final copy = List<CachedRoutine>.from(_items);
    copy.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return copy;
  }

  Future<CachedRoutine?> find(String request) async {
    await load();
    final key = keyOf(request);
    if (key.isEmpty) return null;
    for (final r in _items) {
      if (r.key == key && r.steps.isNotEmpty && r.failCount <= r.successCount) return r;
    }
    return null;
  }

  /// Remembers a successfully completed plan under the request that started it.
  Future<void> remember(String request, Plan plan) async {
    if (_volatile.hasMatch(request.toLowerCase())) return;
    final key = keyOf(request);
    if (key.isEmpty) return;
    // Only the path that worked: skipped and failed steps are left out.
    final good = plan.steps.where((s) => s.status == StepStatus.done).toList();
    if (good.isEmpty) return;
    if (plan.steps.any((s) => s.status == StepStatus.skipped)) return;
    final steps = good.map((s) {
      final json = s.toJson();
      json['status'] = 'pending';
      json['attempts'] = 0;
      json['result'] = '';
      return json;
    }).toList();

    await load();
    final i = _items.indexWhere((r) => r.key == key);
    if (i >= 0) {
      _items[i]
        ..goal = request
        ..steps = steps
        ..successCount += 1
        ..failCount = 0
        ..lastUsed = DateTime.now();
    } else {
      _items.add(CachedRoutine(key: key, goal: request, steps: steps));
    }
    await _persist();
  }

  /// Records how a cached run went; routines that keep failing are dropped.
  Future<void> recordResult(String request, {required bool success}) async {
    await load();
    final key = keyOf(request);
    final i = _items.indexWhere((r) => r.key == key);
    if (i < 0) return;
    final r = _items[i];
    r.lastUsed = DateTime.now();
    if (success) {
      r.successCount += 1;
    } else {
      r.failCount += 1;
      if (r.failCount >= 2 && r.failCount > r.successCount) _items.removeAt(i);
    }
    await _persist();
  }

  Future<void> delete(String key) async {
    await load();
    _items.removeWhere((r) => r.key == key);
    await _persist();
  }

  Future<void> clear() async {
    await load();
    _items.clear();
    await _persist();
  }
}
