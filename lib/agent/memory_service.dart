import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'json_utils.dart';
import 'llm_client.dart';

enum MemoryAddResult { added, duplicate, sensitive, empty }

/// Persistent personal memory stored as a plain markdown file (`memory.md`)
/// inside the app's private documents directory. The user can read and edit it
/// directly from the Memory screen.
class MemoryService {
  MemoryService._();
  static final MemoryService instance = MemoryService._();

  static const List<String> sections = [
    'About the user',
    'Preferences',
    'Facts & notes',
    'Routines & habits',
    'Lessons learned',
  ];
  static const String _title = '# PrivateAgent Memory';

  String _content = '';
  bool _loaded = false;

  static String template() =>
      '$_title\n\n${sections.map((s) => '## $s\n').join('\n')}';

  Future<File> file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/memory.md');
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final f = await file();
      _content = await f.exists() ? await f.readAsString() : template();
    } catch (_) {
      _content = template();
    }
    if (_content.trim().isEmpty) _content = template();
    _loaded = true;
  }

  Future<String> readRaw() async {
    await load();
    return _content;
  }

  Future<void> writeRaw(String markdown) async {
    _content = markdown.trim().isEmpty ? template() : markdown;
    _loaded = true;
    await _persist();
  }

  Future<void> reset() => writeRaw(template());

  Future<void> _persist() async {
    try {
      final f = await file();
      await f.writeAsString(_content, flush: true);
    } catch (_) {}
  }

  // ─── Parsing ───────────────────────────────────────────────────────────

  /// Section title -> entries (bullet text or free-text lines).
  static Map<String, List<String>> parse(String markdown) {
    final result = <String, List<String>>{};
    String? current;
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('## ')) {
        current = line.substring(3).trim();
        result.putIfAbsent(current, () => <String>[]);
      } else if (current != null && line.trim().isNotEmpty && !line.startsWith('#')) {
        var entry = line.trim();
        if (entry.startsWith('- ') || entry.startsWith('* ')) {
          entry = entry.substring(2).trim();
        }
        if (entry.isNotEmpty) result[current]!.add(entry);
      }
    }
    return result;
  }

  Future<Map<String, List<String>>> entries() async {
    await load();
    return parse(_content);
  }

  Future<int> entryCount() async {
    final map = await entries();
    return map.values.fold<int>(0, (sum, list) => sum + list.length);
  }

  // ─── Editing ───────────────────────────────────────────────────────────

  static String canonicalSection(String? name) {
    final n = (name ?? '').toLowerCase();
    for (final s in sections) {
      if (s.toLowerCase() == n) return s;
    }
    if (n.contains('pref')) return 'Preferences';
    if (n.contains('about') || n.contains('profile') || n.contains('user')) {
      return 'About the user';
    }
    if (n.contains('routine') || n.contains('habit')) return 'Routines & habits';
    if (n.contains('lesson')) return 'Lessons learned';
    return 'Facts & notes';
  }

  static final RegExp _secretPattern = RegExp(
    r'(password|passcode|passwd|\bpin\b|\botp\b|\bcvv\b|card number|secret key|api key|\b\d{12,}\b)',
    caseSensitive: false,
  );

  static bool looksSensitive(String text) => _secretPattern.hasMatch(text);

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 2)
      .toSet();

  bool _isDuplicate(String fact) {
    final target = _tokens(fact);
    final lower = fact.toLowerCase();
    for (final list in parse(_content).values) {
      for (final existing in list) {
        final e = existing.toLowerCase();
        if (e == lower || e.contains(lower) || lower.contains(e)) return true;
        final other = _tokens(existing);
        if (target.isEmpty || other.isEmpty) continue;
        final inter = target.intersection(other).length;
        final union = target.union(other).length;
        if (inter / union >= 0.75) return true;
      }
    }
    return false;
  }

  Future<MemoryAddResult> addFact(String section, String fact) async {
    await load();
    final clean = fact.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return MemoryAddResult.empty;
    if (looksSensitive(clean)) return MemoryAddResult.sensitive;
    if (_isDuplicate(clean)) return MemoryAddResult.duplicate;

    final lines = _content.split('\n');
    final target = canonicalSection(section);
    final headerIdx = lines.indexWhere(
      (l) => l.trim().toLowerCase() == '## ${target.toLowerCase()}',
    );

    if (headerIdx < 0) {
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      lines
        ..add('')
        ..add('## $target')
        ..add('- $clean')
        ..add('');
    } else {
      var end = headerIdx + 1;
      while (end < lines.length && !lines[end].startsWith('## ')) {
        end++;
      }
      var insertAt = end;
      while (insertAt - 1 > headerIdx && lines[insertAt - 1].trim().isEmpty) {
        insertAt--;
      }
      lines.insert(insertAt, '- $clean');
      if (insertAt + 1 < lines.length && lines[insertAt + 1].startsWith('## ')) {
        lines.insert(insertAt + 1, '');
      }
    }
    _content = lines.join('\n');
    await _persist();
    return MemoryAddResult.added;
  }

  /// Removes every bullet that contains [fragment]. Returns how many.
  Future<int> removeMatching(String fragment) async {
    await load();
    final needle = fragment.toLowerCase().trim();
    if (needle.length < 3) return 0;
    var removed = 0;
    final kept = <String>[];
    for (final line in _content.split('\n')) {
      final t = line.trim();
      if ((t.startsWith('- ') || t.startsWith('* ')) &&
          t.toLowerCase().contains(needle)) {
        removed++;
      } else {
        kept.add(line);
      }
    }
    if (removed > 0) {
      _content = kept.join('\n');
      await _persist();
    }
    return removed;
  }

  // ─── Prompt context ────────────────────────────────────────────────────

  /// Compact text version of the memory for inclusion in prompts.
  Future<String> promptContext({int maxChars = 3500}) async {
    await load();
    final map = parse(_content);
    final pruneOrder = ['Lessons learned', 'Facts & notes', 'Routines & habits'];

    String build() {
      final b = StringBuffer();
      map.forEach((section, list) {
        if (list.isEmpty) return;
        b.writeln('$section:');
        for (final item in list) {
          b.writeln('- $item');
        }
      });
      return b.toString().trim();
    }

    var text = build();
    var guard = 0;
    while (text.length > maxChars && guard < 500) {
      guard++;
      var pruned = false;
      for (final name in pruneOrder) {
        final list = map[name];
        if (list != null && list.isNotEmpty) {
          list.removeAt(0);
          pruned = true;
          break;
        }
      }
      if (!pruned) {
        text = text.substring(0, maxChars);
        break;
      }
      text = build();
    }
    return text;
  }

  // ─── Learning ──────────────────────────────────────────────────────────

  static final RegExp _explicitRemember = RegExp(
    r"^\s*(?:please\s+)?(?:remember|note|keep in mind|don't forget|dont forget)(?:\s+that)?[:,]?\s+(.+)$",
    caseSensitive: false,
    dotAll: true,
  );

  /// If the message is an explicit "remember that ..." request, returns the
  /// fact to store.
  static String? explicitFact(String message) {
    final m = _explicitRemember.firstMatch(message.trim());
    if (m == null) return null;
    final fact = (m.group(1) ?? '').trim();
    return fact.isEmpty ? null : fact;
  }

  static final RegExp _learnCue = RegExp(
    r"\b(my|i am|i'm|i live|i work|i like|i love|i hate|i prefer|i usually|i always|i never|call me|from now on|every (day|morning|night|week)|favou?rite|allergic|birthday|wife|husband|girlfriend|boyfriend|mom|mum|dad|sister|brother|boss)\b",
    caseSensitive: false,
  );

  static bool worthLearning(String userText) =>
      userText.trim().length >= 12 && _learnCue.hasMatch(userText);

  /// Asks the model whether the exchange contains durable facts worth keeping
  /// and stores them. Never throws.
  Future<int> learnFromTurn(
    LlmClient llm, {
    required String userText,
    required String assistantText,
  }) async {
    try {
      await load();
      final existing = await promptContext(maxChars: 1500);
      final prompt = '''
You maintain the long-term memory of a personal phone assistant.
From the exchange below, extract ONLY durable facts about the USER that will help in future conversations (identity, preferences, relationships, routines, apps and services they use, recurring needs).
Ignore one-off requests, temporary states, and anything secret such as passwords, PINs, card numbers or ID numbers.
Write each fact as a short third-person statement (for example "Prefers dark mode").
Do not repeat anything already in memory.

EXISTING MEMORY:
${existing.isEmpty ? '(empty)' : existing}

USER: $userText
ASSISTANT: ${assistantText.length > 600 ? assistantText.substring(0, 600) : assistantText}

Return ONLY JSON: {"add":[{"section":"About the user|Preferences|Facts & notes|Routines & habits","text":"..."}],"remove":["fragment of an outdated fact"]}
Use empty arrays when there is nothing to store. Add at most 3 facts.''';

      final res = await llm.complete(
        [
          {'role': 'system', 'content': 'You output only compact JSON.'},
          {'role': 'user', 'content': prompt},
        ],
        temperature: 0.1,
        maxTokens: 600,
        retries: 1,
      );
      final json = JsonUtils.extractObject(res.content);
      if (json == null) return 0;

      var changed = 0;
      final removals = json['remove'];
      if (removals is List) {
        for (final r in removals.take(3)) {
          changed += await removeMatching(r.toString());
        }
      }
      final adds = json['add'];
      if (adds is List) {
        for (final a in adds.take(3)) {
          if (a is Map) {
            final result = await addFact(
              JsonUtils.str(a['section']),
              JsonUtils.str(a['text']),
            );
            if (result == MemoryAddResult.added) changed++;
          }
        }
      }
      return changed;
    } catch (_) {
      return 0;
    }
  }
}
