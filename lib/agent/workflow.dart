import 'safe_cast.dart';
import 'dart:math' as math;
import '../models/saved_skill.dart';

/// The foreground package plus the accessibility nodes visible right now.
class ScreenSnap {
  final String pkg;
  final List<Map<String, dynamic>> nodes;
  const ScreenSnap(this.pkg, this.nodes);
}

/// Helpers for recording and replaying exact UI workflows.
///
/// A recorded step keeps, besides the action itself, the app it ran in, a
/// signature of the screen it was performed on, and the exact target that was
/// tapped (label, class, centre coordinates). Replaying then needs no model
/// call: wait until the screen looks as recorded, tap the same element (found
/// live, falling back to the recorded coordinates), continue.
class WorkflowKit {
  WorkflowKit._();

  static final RegExp _noise = RegExp(
    r'(battery|percent|do not disturb|three bars|stop macro|signal|wifi|wi-fi)',
    caseSensitive: false,
  );
  static final RegExp _digits = RegExp(r'\d{3,}');
  static final RegExp _time = RegExp(r'^\d{1,2}:\d{2}');

  static String _labelOf(Map<String, dynamic> node) {
    final text = (node['text'] ?? '').toString().trim();
    if (text.isNotEmpty) return text;
    return (node['contentDescription'] ?? '').toString().trim();
  }

  static num _n(dynamic v) => v is num ? v : 0;

  static Map<String, dynamic>? _bounds(Map<String, dynamic> node) {
    final b = node['bounds'];
    if (b is Map) return Map<String, dynamic>.from(b);
    return null;
  }

  static double centerX(Map<String, dynamic> node) {
    final b = _bounds(node);
    return b == null ? 0 : (_n(b['left']) + _n(b['right'])) / 2;
  }

  static double centerY(Map<String, dynamic> node) {
    final b = _bounds(node);
    return b == null ? 0 : (_n(b['top']) + _n(b['bottom'])) / 2;
  }

  static double _area(Map<String, dynamic> node) {
    final b = _bounds(node);
    if (b == null) return double.infinity;
    final w = _n(b['right']) - _n(b['left']);
    final h = _n(b['bottom']) - _n(b['top']);
    return (w * h).toDouble();
  }

  /// Stable, human-readable labels that identify a screen (tabs, buttons,
  /// headings). Dynamic content such as numbers and clock times is left out.
  static List<String> labels(List<Map<String, dynamic>> nodes, {int max = 30}) {
    final out = <String>[];
    final seen = <String>{};
    for (final node in nodes) {
      final label = _labelOf(node);
      if (label.length < 2 || label.length > 28) continue;
      if (_digits.hasMatch(label) || _time.hasMatch(label) || _noise.hasMatch(label)) continue;
      final interactive = node['isClickable'] == true || node['isEditable'] == true;
      if (!interactive && label.length > 20) continue;
      final lower = label.toLowerCase();
      if (seen.add(lower)) out.add(lower);
      if (out.length >= max) break;
    }
    return out;
  }

  /// True when at least [minCoverage] of the recorded labels are on screen now.
  static bool matches(List<String> recorded, List<String> current, {double minCoverage = 0.6}) {
    if (recorded.length < 2) return true;
    final have = current.toSet();
    final hit = recorded.where(have.contains).length;
    return hit / recorded.length >= minCoverage;
  }

  /// The smallest node containing the point, preferring clickable ones.
  static Map<String, dynamic>? nodeAt(List<Map<String, dynamic>> nodes, double x, double y) {
    Map<String, dynamic>? best;
    var bestScore = double.infinity;
    for (final node in nodes) {
      final b = _bounds(node);
      if (b == null) continue;
      if (x < _n(b['left']) || x > _n(b['right']) || y < _n(b['top']) || y > _n(b['bottom'])) {
        continue;
      }
      var score = _area(node);
      if (node['isClickable'] != true && node['isEditable'] != true) score *= 4;
      if (score < bestScore) {
        bestScore = score;
        best = node;
      }
    }
    return best;
  }

  /// A node whose text or description matches [label] (exact first, then
  /// "contains"), nearest to (cx, cy) when there are several.
  static Map<String, dynamic>? findByLabel(
    List<Map<String, dynamic>> nodes,
    String label, {
    double cx = 0,
    double cy = 0,
    String cls = '',
  }) {
    final want = label.trim().toLowerCase();
    if (want.isEmpty) return null;

    List<Map<String, dynamic>> pick(bool exact) {
      return nodes.where((n) {
        final t = (n['text'] ?? '').toString().trim().toLowerCase();
        final d = (n['contentDescription'] ?? '').toString().trim().toLowerCase();
        if (exact) return t == want || d == want;
        return (t.isNotEmpty && t.contains(want)) || (d.isNotEmpty && d.contains(want));
      }).toList();
    }

    var candidates = pick(true);
    if (candidates.isEmpty) candidates = pick(false);
    if (candidates.isEmpty) return null;

    if (cls.isNotEmpty) {
      final sameClass = candidates.where((n) => (n['className'] ?? '').toString() == cls).toList();
      if (sameClass.isNotEmpty) candidates = sameClass;
    }
    candidates.sort((a, b) {
      final da = _dist(centerX(a), centerY(a), cx, cy);
      final db = _dist(centerX(b), centerY(b), cx, cy);
      return da.compareTo(db);
    });
    return candidates.first;
  }

  static double _dist(double ax, double ay, double bx, double by) =>
      math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

  /// Everything worth remembering about one step, taken on the screen the
  /// step was performed on.
  static Map<String, dynamic> stepMeta(
    String action,
    Map<String, dynamic> params,
    ScreenSnap? pre,
  ) {
    if (pre == null) return <String, dynamic>{};
    final meta = <String, dynamic>{
      'pkg': pre.pkg,
      'sig': labels(pre.nodes),
    };
    Map<String, dynamic>? target;
    if (action == 'click_text') {
      target = findByLabel(pre.nodes, (params['text'] ?? '').toString());
    } else if (action == 'click_at') {
      final x = asDouble(params['x']) ?? 0;
      final y = asDouble(params['y']) ?? 0;
      target = nodeAt(pre.nodes, x, y);
    }
    if (target != null) {
      meta['tx'] = (target['text'] ?? '').toString();
      meta['td'] = (target['contentDescription'] ?? '').toString();
      meta['tc'] = (target['className'] ?? '').toString();
      meta['cx'] = centerX(target).round();
      meta['cy'] = centerY(target).round();
    }
    return meta;
  }

  static List<String> stringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  /// Removes detours: "do something, then go back to where you were".
  static List<ActionStep> compact(List<ActionStep> steps) {
    final out = List<ActionStep>.from(steps);
    var i = 1;
    while (i < out.length) {
      final step = out[i];
      final prev = out[i - 1];
      final hasNext = i + 1 < out.length;
      if (step.action == 'press_back' &&
          hasNext &&
          prev.meta.isNotEmpty &&
          out[i + 1].meta.isNotEmpty &&
          prev.meta['pkg'] == out[i + 1].meta['pkg'] &&
          matches(stringList(prev.meta['sig']), stringList(out[i + 1].meta['sig']), minCoverage: 0.85) &&
          (prev.action == 'click_text' || prev.action == 'click_at')) {
        out.removeRange(i - 1, i + 1);
        i = math.max(1, i - 1);
        continue;
      }
      if (step.action == 'wait') {
        out.removeAt(i);
        continue;
      }
      i++;
    }
    return out;
  }
}
