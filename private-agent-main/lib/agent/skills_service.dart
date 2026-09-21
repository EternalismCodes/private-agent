import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'json_utils.dart';
import 'llm_client.dart';

/// A reusable, named set of instructions the agent can follow.
///
/// Skills are authored by the user or distilled by the agent from a task it
/// completed. Relevant skills are injected into the planner's prompt, and any
/// skill can be run on demand.
class AgentSkill {
  final String id;
  String name;
  String description;
  List<String> triggers;
  String instructions;
  bool enabled;
  int useCount;
  String source; // 'user' | 'agent' | 'builtin'
  DateTime createdAt;
  DateTime updatedAt;

  AgentSkill({
    required this.id,
    required this.name,
    this.description = '',
    List<String>? triggers,
    required this.instructions,
    this.enabled = true,
    this.useCount = 0,
    this.source = 'user',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : triggers = triggers ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'triggers': triggers,
        'instructions': instructions,
        'enabled': enabled,
        'use_count': useCount,
        'source': source,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AgentSkill.fromJson(Map<String, dynamic> json) => AgentSkill(
        id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch).toString(),
        name: (json['name'] ?? 'Untitled skill').toString(),
        description: (json['description'] ?? '').toString(),
        triggers: json['triggers'] is List
            ? (json['triggers'] as List).map((e) => e.toString()).toList()
            : <String>[],
        instructions: (json['instructions'] ?? '').toString(),
        enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
        useCount: json['use_count'] is num ? (json['use_count'] as num).toInt() : 0,
        source: (json['source'] ?? 'user').toString(),
        createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
        updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
      );
}

class SkillsService {
  SkillsService._();
  static final SkillsService instance = SkillsService._();

  final List<AgentSkill> _items = [];
  bool _loaded = false;

  List<AgentSkill> get items => List.unmodifiable(_items);

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/agent_skills.json');
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
            if (e is Map) _items.add(AgentSkill.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      } else {
        _items.addAll(_seedSkills());
        await _persist();
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_items.map((s) => s.toJson()).toList()), flush: true);
    } catch (_) {}
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> save(AgentSkill skill) async {
    await load();
    skill.updatedAt = DateTime.now();
    final i = _items.indexWhere((s) => s.id == skill.id);
    if (i >= 0) {
      _items[i] = skill;
    } else {
      _items.insert(0, skill);
    }
    await _persist();
  }

  Future<void> delete(String id) async {
    await load();
    _items.removeWhere((s) => s.id == id);
    await _persist();
  }

  Future<void> recordUse(String id) async {
    await load();
    final i = _items.indexWhere((s) => s.id == id);
    if (i >= 0) {
      _items[i].useCount++;
      await _persist();
    }
  }

  AgentSkill? byName(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final s in _items) {
      if (s.enabled && s.name.toLowerCase() == n) return s;
    }
    for (final s in _items) {
      if (s.enabled && (s.name.toLowerCase().contains(n) || n.contains(s.name.toLowerCase()))) {
        return s;
      }
    }
    return null;
  }

  static const Set<String> _stop = {
    'the', 'and', 'for', 'with', 'that', 'this', 'from', 'into', 'then', 'please',
    'can', 'you', 'my', 'me', 'to', 'in', 'on', 'of', 'a', 'an', 'it', 'is', 'do',
    'open', 'go', 'get',
  };

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 2 && !_stop.contains(w))
      .toSet();

  /// Relevance score of [skill] for [query].
  static int score(AgentSkill skill, String query) {
    final q = query.toLowerCase();
    var points = 0;
    if (skill.name.isNotEmpty && q.contains(skill.name.toLowerCase())) points += 5;
    for (final t in skill.triggers) {
      final trig = t.toLowerCase().trim();
      if (trig.isNotEmpty && q.contains(trig)) points += 4;
    }
    final qTokens = _tokens(query);
    final sTokens = _tokens('${skill.name} ${skill.triggers.join(' ')} ${skill.description}');
    points += qTokens.intersection(sTokens).length;
    return points;
  }

  /// The most relevant enabled skills for a request.
  List<AgentSkill> match(String query, {int limit = 2, int minScore = 2}) {
    final scored = <MapEntry<AgentSkill, int>>[];
    for (final s in _items) {
      if (!s.enabled) continue;
      final sc = score(s, query);
      if (sc >= minScore) scored.add(MapEntry(s, sc));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  /// Instructions of matching skills, formatted for a prompt.
  String promptFor(String query) {
    final matches = match(query);
    if (matches.isEmpty) return '';
    return matches.map((s) => 'Skill "${s.name}":\n${s.instructions}').join('\n\n');
  }

  /// One-line catalog so the model knows which skills it can run by name.
  String catalog() {
    final enabled = _items.where((s) => s.enabled).take(25);
    return enabled
        .map((s) => '- ${s.name}${s.description.isEmpty ? '' : ': ${s.description}'}')
        .join('\n');
  }

  /// Turns a successfully completed task into a reusable skill.
  Future<AgentSkill?> distill(
    LlmClient llm, {
    required String goal,
    required List<String> trace,
  }) async {
    try {
      final traceText = trace.take(30).join('\n');
      final prompt = '''
A phone assistant just completed a task. Turn it into a reusable skill that could be run again with different details.

TASK: $goal

WHAT HAPPENED:
$traceText

Return ONLY JSON:
{"name": "2-4 word title", "description": "one sentence", "triggers": ["short phrases a user might say"], "instructions": "numbered, generic steps; use <placeholders> for details that change"}''';
      final res = await llm.complete(
        [
          {'role': 'system', 'content': 'You output only compact JSON.'},
          {'role': 'user', 'content': prompt},
        ],
        temperature: 0.2,
        maxTokens: 900,
        retries: 1,
      );
      final json = JsonUtils.extractObject(res.content);
      if (json == null) return null;
      final instructions = JsonUtils.str(json['instructions']);
      if (instructions.isEmpty) return null;
      return AgentSkill(
        id: newId(),
        name: JsonUtils.str(json['name'], goal.length > 30 ? goal.substring(0, 30) : goal),
        description: JsonUtils.str(json['description']),
        triggers: json['triggers'] is List
            ? (json['triggers'] as List).map((e) => e.toString()).take(6).toList()
            : <String>[],
        instructions: instructions,
        source: 'agent',
      );
    } catch (_) {
      return null;
    }
  }

  List<AgentSkill> _seedSkills() => [
        AgentSkill(
          id: 'builtin_whatsapp',
          name: 'Send a WhatsApp message',
          description: 'Message a contact through WhatsApp.',
          triggers: ['whatsapp', 'send message on whatsapp'],
          instructions:
              '1. Open WhatsApp.\n2. Tap the search icon and type the contact name.\n3. Open the matching chat.\n4. Tap the message box, type the message, then tap Send.\n5. Confirm the message appears in the chat.',
          source: 'builtin',
        ),
        AgentSkill(
          id: 'builtin_web_lookup',
          name: 'Look something up online',
          description: 'Search the web in Chrome and report the answer.',
          triggers: ['look up', 'search the web', 'google'],
          instructions:
              '1. Open Chrome.\n2. Tap the address bar, type the query and submit.\n3. Read the top result or featured snippet.\n4. Report the answer in the final message instead of only saying "done".',
          source: 'builtin',
        ),
        AgentSkill(
          id: 'builtin_reminder',
          name: 'Set a reminder',
          description: 'Create an alarm or timer for something later.',
          triggers: ['remind me', 'set a reminder'],
          instructions:
              '1. Work out the exact time from the request (use the current date and time).\n2. Use the set_alarm or set_timer action with a clear label.\n3. Tell the user exactly when it will ring.',
          source: 'builtin',
        ),
      ];
}
