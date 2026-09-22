import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/saved_skill.dart';

class SkillMemoryService {
  List<SavedSkill> _skills = [];
  bool _isLoaded = false;

  Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/skills_memory.jsonl');
  }

  Future<void> _loadSkills() async {
    if (_isLoaded) return;
    try {
      final file = await _localFile;
      if (!await file.exists()) {
        _isLoaded = true;
        return;
      }
      final lines = await file.readAsLines();
      _skills = lines
          .where((line) => line.trim().isNotEmpty)
          .map((line) => SavedSkill.fromJson(jsonDecode(line) as Map<String, dynamic>))
          .toList();
      _isLoaded = true;
    } catch (e) {
      print('Failed to load skills: $e');
    }
  }

  Future<void> _saveAllSkills() async {
    try {
      final file = await _localFile;
      final lines = _skills.map((s) => jsonEncode(s.toJson())).join('\n');
      await file.writeAsString(lines + (lines.isNotEmpty ? '\n' : ''));
    } catch (e) {
      print('Failed to save skills: $e');
    }
  }

  List<String> _extractKeywords(String text) {
    final stopWords = {'to', 'and', 'the', 'a', 'in', 'of', 'for', 'on', 'with', 'at', 'by', 'from', 'go', 'turn', 'open'};
    final words = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '').split(RegExp(r'\s+'));
    return words.where((w) => w.isNotEmpty && !stopWords.contains(w)).toList();
  }

  double _jaccardSimilarity(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final setA = a.toSet();
    final setB = b.toSet();
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return intersection / union;
  }

  Future<SavedSkill?> findSkill(String taskGoal) async {
    await _loadSkills();
    if (_skills.isEmpty) return null;

    final queryKeywords = _extractKeywords(taskGoal);
    SavedSkill? bestMatch;
    double highestSim = 0.0;

    for (final skill in _skills) {
      final sim = _jaccardSimilarity(queryKeywords, skill.taskKeywords);
      if (sim > highestSim) {
        highestSim = sim;
        bestMatch = skill;
      }
    }

    // Exact-ish matches only: a replay repeats literal taps and typed text.
    if (highestSim >= 0.85) {
      return bestMatch;
    }
    return null;
  }

  Future<void> saveSkill(
    String taskGoal,
    List<ActionStep> steps, {
    String finalPkg = '',
    List<String> finalSig = const [],
  }) async {
    await _loadSkills();
    if (steps.isEmpty) return;

    // "open youtube and search for cats" -> a reusable template whose typed
    // text is a slot, so "search dogs on youtube" can reuse the same taps.
    final tpl = detectTemplate(taskGoal, steps);
    if (tpl != null) {
      final words = tokens(tpl.example).toSet();
      bool dynamicLabel(String label) {
        final l = label.toLowerCase();
        return words.any(l.contains);
      }

      for (final step in steps) {
        final sig = step.meta['sig'];
        if (sig is List) {
          step.meta['sig'] = sig.map((e) => e.toString()).where((l) => !dynamicLabel(l)).toList();
        }
      }
      finalSig = finalSig.where((l) => !dynamicLabel(l)).toList();
    }

    final queryKeywords = _extractKeywords(taskGoal);
    for (final skill in _skills) {
      final sameTemplate = tpl != null &&
          skill.isTemplate &&
          skill.skeleton.length == tpl.skeleton.length &&
          skill.skeleton.toSet().containsAll(tpl.skeleton);
      if (sameTemplate || _jaccardSimilarity(queryKeywords, skill.taskKeywords) > 0.8) {
        skill.successCount++;
        skill.lastUsed = DateTime.now();
        final oldExact = skill.steps.any((s) => s.meta.isNotEmpty);
        final newExact = steps.any((s) => s.meta.isNotEmpty);
        final replace = skill.failCount > 0 ||
            (newExact && !oldExact) ||
            (newExact == oldExact && steps.length < skill.steps.length);
        if (replace) {
          skill.steps.clear();
          skill.steps.addAll(steps);
          skill.failCount = 0;
          skill.finalPkg = finalPkg;
          skill.finalSig = List<String>.from(finalSig);
          skill.skeleton = tpl?.skeleton ?? <String>[];
          skill.slotExample = tpl?.example ?? '';
        }
        await _saveAllSkills();
        return;
      }
    }

    final newSkill = SavedSkill(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      task: taskGoal,
      taskKeywords: queryKeywords,
      successCount: 1,
      failCount: 0,
      lastUsed: DateTime.now(),
      steps: steps,
      finalPkg: finalPkg,
      finalSig: List<String>.from(finalSig),
      skeleton: tpl?.skeleton,
      slotExample: tpl?.example ?? '',
    );
    _skills.add(newSkill);
    await _saveAllSkills();
  }

  /// All learned workflows, freshly read from disk (newest first).
  Future<List<SavedSkill>> listAll() async {
    _isLoaded = false;
    _skills = [];
    await _loadSkills();
    final copy = List<SavedSkill>.from(_skills);
    copy.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return copy;
  }

  Future<void> deleteSkill(String skillId) async {
    _isLoaded = false;
    _skills = [];
    await _loadSkills();
    _skills.removeWhere((s) => s.id == skillId);
    await _saveAllSkills();
  }

  Future<void> clearAll() async {
    _skills = [];
    _isLoaded = true;
    await _saveAllSkills();
  }

  Future<void> recordReplay(String skillId, int millis) async {
    await _loadSkills();
    final index = _skills.indexWhere((s) => s.id == skillId);
    if (index != -1) {
      _skills[index].replayCount++;
      _skills[index].lastReplayMs = millis;
      _skills[index].lastUsed = DateTime.now();
      await _saveAllSkills();
    }
  }

  Future<void> recordFailure(String skillId) async {
    await _loadSkills();
    final index = _skills.indexWhere((s) => s.id == skillId);
    if (index != -1) {
      _skills[index].failCount++;
      await _saveAllSkills();
    }
  }

  // ─── Parameterised workflows ──────────────────────────────────────────

  static const Set<String> _fillers = {
    'to', 'and', 'the', 'a', 'an', 'in', 'of', 'for', 'on', 'with', 'at', 'by',
    'from', 'go', 'turn', 'please', 'then', 'me', 'my', 'it', 'up', 'app',
    'application', 'can', 'you', 'could', 'would', 'now', 'just', 'some',
    'something', 'about', 'using', 'via', 'into',
  };
  static const Map<String, String> _synonyms = {
    'look': 'search',
    'lookup': 'search',
    'find': 'search',
    'google': 'search',
    'launch': 'open',
    'start': 'open',
    'watch': 'play',
  };
  static const Set<String> _actionVerbs = {
    'click', 'tap', 'like', 'subscribe', 'share', 'comment', 'send', 'message',
    'call', 'download', 'install', 'buy', 'order', 'delete', 'post', 'follow',
    'unfollow', 'save', 'add', 'remove',
  };

  /// Canonical form of a word ('' for filler such as "open", "for", "the").
  static String canon(String raw) {
    var w = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (w.isEmpty) return '';
    w = _synonyms[w] ?? w;
    if (w == 'open' || _fillers.contains(w)) return '';
    if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) {
      w = w.substring(0, w.length - 1);
    }
    return w;
  }

  static List<String> tokens(String text) => text
      .split(RegExp(r'\s+'))
      .map(canon)
      .where((t) => t.isNotEmpty)
      .toList();

  /// Finds out whether a goal contained one piece of typed text that can vary.
  static TemplateInfo? detectTemplate(String goal, List<ActionStep> steps) {
    final typed = <String>{};
    String example = '';
    for (final step in steps) {
      if (step.action != 'type_text') continue;
      final t = (step.params['text'] ?? '').toString().trim();
      if (t.isEmpty) continue;
      if (typed.add(t.toLowerCase()) && example.isEmpty) example = t;
    }
    if (typed.length != 1) return null;
    final typedTokens = tokens(example);
    final goalTokens = tokens(goal);
    if (typedTokens.isEmpty || !typedTokens.every(goalTokens.contains)) return null;
    final skeleton = goalTokens.where((t) => !typedTokens.contains(t)).toSet().toList();
    if (skeleton.length < 2) return null;
    return TemplateInfo(skeleton, example);
  }

  /// The variable part of [goal] for a template with [skeleton], or null when
  /// the goal is not that task (missing words, extra actions, too long).
  static String? extractValue(String goal, List<String> skeleton) {
    final want = skeleton.toSet();
    final seen = <String>{};
    final value = <String>[];
    var pending = <String>[];
    for (final raw in goal.split(RegExp(r'\s+'))) {
      final word = raw.replaceAll(RegExp(r'^[^A-Za-z0-9]+|[^A-Za-z0-9]+$'), '');
      if (word.isEmpty) continue;
      final c = canon(word);
      if (c.isEmpty) {
        if (value.isNotEmpty) pending.add(word);
        continue;
      }
      if (want.contains(c)) {
        seen.add(c);
        pending = <String>[];
        continue;
      }
      if (_actionVerbs.contains(c)) return null;
      value.addAll(pending);
      pending = <String>[];
      value.add(word);
    }
    if (seen.length != want.length) return null;
    if (value.isEmpty || value.length > 8) return null;
    return value.join(' ');
  }

  /// The learned workflow for a request: an exact one, or a template whose
  /// typed text is replaced by the new value.
  Future<SkillMatch?> matchSkill(String goal) async {
    _isLoaded = false;
    _skills = [];
    await _loadSkills();
    final exact = await findSkill(goal);
    if (exact != null) return SkillMatch(exact, null);

    SavedSkill? best;
    String? bestValue;
    for (final skill in _skills) {
      if (!skill.isTemplate || !skill.isReliable) continue;
      final value = extractValue(goal, skill.skeleton);
      if (value != null && (best == null || skill.skeleton.length > best.skeleton.length)) {
        best = skill;
        bestValue = value;
      }
    }
    return best == null ? null : SkillMatch(best, bestValue);
  }
}


class SkillMatch {
  final SavedSkill skill;

  /// The new value for the template's typed text (null for an exact match).
  final String? value;
  const SkillMatch(this.skill, this.value);
}

class TemplateInfo {
  final List<String> skeleton;
  final String example;
  const TemplateInfo(this.skeleton, this.example);
}
