import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Key/value store for secrets.
///
/// Values are written to the Android Keystore-backed encrypted storage. If the
/// keystore is unavailable on a device (or throws), the store transparently
/// falls back to a private file inside the app sandbox so the app keeps
/// working. [usingFallback] tells the UI which of the two is active.
class SecretStore {
  SecretStore._();
  static final SecretStore instance = SecretStore._();

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  bool _secureBroken = false;

  bool get usingFallback => _secureBroken;

  String _safeName(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  Future<File> _fallbackFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/vault_fallback');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/${_safeName(key)}.secret');
  }

  Future<String?> read(String key) async {
    if (!_secureBroken) {
      try {
        final value = await _secure.read(key: key);
        if (value != null) return value;
      } catch (_) {
        _secureBroken = true;
      }
    }
    try {
      final file = await _fallbackFile(key);
      if (await file.exists()) return await file.readAsString();
    } catch (_) {}
    return null;
  }

  /// Returns true when the value was persisted somewhere.
  Future<bool> write(String key, String value) async {
    if (!_secureBroken) {
      try {
        await _secure.write(key: key, value: value);
        // Make sure a stale plaintext copy does not linger.
        try {
          final file = await _fallbackFile(key);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return true;
      } catch (_) {
        _secureBroken = true;
      }
    }
    try {
      final file = await _fallbackFile(key);
      await file.writeAsString(value, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String key) async {
    if (!_secureBroken) {
      try {
        await _secure.delete(key: key);
      } catch (_) {
        _secureBroken = true;
      }
    }
    try {
      final file = await _fallbackFile(key);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// One saved login / account.
class Credential {
  final String id;
  String label;
  String username;
  String password;
  String url;
  String notes;
  DateTime updatedAt;

  Credential({
    required this.id,
    required this.label,
    this.username = '',
    this.password = '',
    this.url = '',
    this.notes = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'username': username,
        'password': password,
        'url': url,
        'notes': notes,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Credential.fromJson(Map<String, dynamic> json) => Credential(
        id: (json['id'] ?? DateTime.now().microsecondsSinceEpoch).toString(),
        label: (json['label'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        password: (json['password'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        notes: (json['notes'] ?? '').toString(),
        updatedAt:
            DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
                DateTime.now(),
      );
}

/// Encrypted account vault. The agent can *use* a credential (type it into a
/// field) without the secret ever being sent to the language model.
class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();

  static const String _storageKey = 'vault_accounts_v1';

  final List<Credential> _items = [];
  bool _loaded = false;

  List<Credential> get items => List.unmodifiable(_items);
  bool get usingFallback => SecretStore.instance.usingFallback;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _items.clear();
    try {
      final raw = await SecretStore.instance.read(_storageKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              _items.add(Credential.fromJson(Map<String, dynamic>.from(entry)));
            }
          }
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_items.map((c) => c.toJson()).toList());
    await SecretStore.instance.write(_storageKey, raw);
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> save(Credential credential) async {
    await load();
    credential.updatedAt = DateTime.now();
    final index = _items.indexWhere((c) => c.id == credential.id);
    if (index >= 0) {
      _items[index] = credential;
    } else {
      _items.add(credential);
    }
    await _persist();
  }

  Future<void> delete(String id) async {
    await load();
    _items.removeWhere((c) => c.id == id);
    await _persist();
  }

  Future<void> clear() async {
    await load();
    _items.clear();
    await SecretStore.instance.delete(_storageKey);
  }

  /// Finds an account by label, username or URL (case-insensitive).
  Credential? find(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final c in _items) {
      if (c.label.toLowerCase() == q) return c;
    }
    for (final c in _items) {
      if (c.label.toLowerCase().contains(q) ||
          q.contains(c.label.toLowerCase()) ||
          (c.url.isNotEmpty && c.url.toLowerCase().contains(q)) ||
          (c.username.isNotEmpty && c.username.toLowerCase() == q)) {
        return c;
      }
    }
    return null;
  }

  /// The secret for [field] ('password' or 'username') of [account].
  Future<String?> secretFor(String account, String field) async {
    await load();
    final c = find(account);
    if (c == null) return null;
    final f = field.toLowerCase().trim();
    if (f == 'username' || f == 'user' || f == 'email' || f == 'login') {
      return c.username.isEmpty ? null : c.username;
    }
    return c.password.isEmpty ? null : c.password;
  }

  /// Labels only. Usernames and passwords are never included in anything sent
  /// to the model; the agent refers to an account by label and the app fills
  /// the values in locally.
  String promptSummary() {
    if (_items.isEmpty) return '';
    return _items.take(25).map((c) => '- ${c.label}').join('\n');
  }
}
