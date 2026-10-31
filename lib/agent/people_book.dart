import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Someone the user talks about with nicknames ("mom", "boss", "bro").
class Person {
  final String id;
  final List<String> aliases; // what the user calls them
  final String contact; // name to look up in the phone's contacts
  final String phone; // optional number (used directly when set)
  final String relation; // free note, e.g. "my mother"
  final String via; // preferred way to reach them: WhatsApp / Phone call / SMS / Telegram …

  const Person({
    required this.id,
    required this.aliases,
    this.contact = '',
    this.phone = '',
    this.relation = '',
    this.via = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'aliases': aliases,
        'contact': contact,
        'phone': phone,
        'relation': relation,
        'via': via,
      };

  static Person fromJson(Map<String, dynamic> j) => Person(
        id: (j['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
        aliases: ((j['aliases'] as List?) ?? const []).map((e) => e.toString()).toList(),
        contact: (j['contact'] ?? '').toString(),
        phone: (j['phone'] ?? '').toString(),
        relation: (j['relation'] ?? '').toString(),
        via: (j['via'] ?? '').toString(),
      );
}

/// Aliases for people plus the apps used to reach them. Aliases are given to
/// the AI so "call mom" or "message my boss" means the right person, and are
/// also resolved directly when a call/SMS/WhatsApp action runs. The app used
/// for each contact is learned over time, so "message Sam" can pick the app
/// you normally use for Sam.
class PeopleBook extends ChangeNotifier {
  PeopleBook._();
  static final PeopleBook instance = PeopleBook._();

  static const _kPeople = 'people_book_v1';
  static const _kHabits = 'people_habits_v1';

  List<Person> _people = [];
  // contact (lowercase) -> app -> times used
  Map<String, Map<String, int>> _habits = {};
  bool _loaded = false;

  List<Person> get people => List.unmodifiable(_people);

  /// Forget what is in memory so the next [load] re-reads storage (after a restore).
  void reset() {
    _people = [];
    _habits = {};
    _loaded = false;
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kPeople);
      if (raw != null && raw.isNotEmpty) {
        _people = (jsonDecode(raw) as List).whereType<Map>().map((m) => Person.fromJson(Map<String, dynamic>.from(m))).toList();
      }
      final h = p.getString(_kHabits);
      if (h != null && h.isNotEmpty) {
        final m = jsonDecode(h) as Map;
        _habits = m.map((k, v) => MapEntry(k.toString(), (v as Map).map((a, b) => MapEntry(a.toString(), (b as num).toInt()))));
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPeople, jsonEncode(_people.map((e) => e.toJson()).toList()));
    await p.setString(_kHabits, jsonEncode(_habits));
    notifyListeners();
  }

  Future<void> upsert(Person person) async {
    await load();
    final i = _people.indexWhere((e) => e.id == person.id);
    if (i >= 0) {
      _people[i] = person;
    } else {
      _people.add(person);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    await load();
    _people.removeWhere((e) => e.id == id);
    await _save();
  }

  static String _norm(String s) {
    var t = s.toLowerCase().trim();
    for (final lead in const ['my ', 'to ', 'the ']) {
      if (t.startsWith(lead)) t = t.substring(lead.length).trim();
    }
    return t;
  }

  /// The person [name] refers to (an alias or their contact name), if any.
  Person? resolve(String? name) {
    if (name == null) return null;
    final q = _norm(name);
    if (q.isEmpty) return null;
    for (final p in _people) {
      if (p.aliases.any((a) => _norm(a) == q) || (p.contact.isNotEmpty && _norm(p.contact) == q)) return p;
    }
    return null;
  }

  /// Remember that [contact] was reached through [app] (e.g. "WhatsApp").
  Future<void> noteUse(String contact, String app) async {
    final key = _norm(resolve(contact)?.contact.isNotEmpty == true ? resolve(contact)!.contact : contact);
    if (key.isEmpty || app.isEmpty) return;
    await load();
    final m = _habits.putIfAbsent(key, () => {});
    m[app] = (m[app] ?? 0) + 1;
    if (_habits.length > 60) _habits.remove(_habits.keys.first);
    await _save();
  }

  String? _topApp(String contactKey) {
    final m = _habits[contactKey];
    if (m == null || m.isEmpty) return null;
    final e = m.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return e.value >= 2 ? e.key : null; // only once it is a real habit
  }

  /// Prompt block for the AI; empty when nothing is set up.
  String promptSection() {
    final b = StringBuffer();
    if (_people.isNotEmpty) {
      b.writeln('PEOPLE THE USER KNOWS (when the user says one of these names they mean that person — use the contact name/number for calls and messages, and the preferred app when the user does not name one):');
      for (final p in _people) {
        final aliases = p.aliases.where((a) => a.trim().isNotEmpty).map((a) => '"${a.trim()}"').join(', ');
        if (aliases.isEmpty) continue;
        final parts = <String>[
          if (p.contact.isNotEmpty) 'contact "${p.contact}"',
          if (p.phone.isNotEmpty) 'number ${p.phone}',
          if (p.relation.isNotEmpty) p.relation,
          if (p.via.isNotEmpty) 'reach via ${p.via}',
        ];
        b.writeln('- $aliases = ${parts.isEmpty ? 'a saved person' : parts.join(', ')}');
      }
    }
    final habitLines = <String>[];
    for (final k in _habits.keys) {
      final app = _topApp(k);
      final known = _people.any((p) => p.via.isNotEmpty && _norm(p.contact) == k);
      if (app != null && !known) habitLines.add('- $k: usually contacted via $app');
    }
    if (habitLines.isNotEmpty) {
      b.writeln('\nCONTACT HABITS (learned from past requests; use when the user does not say which app):');
      for (final l in habitLines.take(15)) {
        b.writeln(l);
      }
    }
    return b.toString().trim();
  }
}
