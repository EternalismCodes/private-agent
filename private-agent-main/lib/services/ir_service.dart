import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IrCode {
  final String name; // e.g. "ac", "tv", "ac 2"
  final int frequency; // carrier frequency in Hz, e.g. 38000
  final List<int> pattern; // alternating on/off microsecond durations
  IrCode(this.name, this.frequency, this.pattern);

  Map<String, dynamic> toJson() => {'name': name, 'frequency': frequency, 'pattern': pattern};
  factory IrCode.fromJson(Map<String, dynamic> j) => IrCode(
        '${j['name']}',
        (j['frequency'] as num?)?.toInt() ?? 38000,
        (j['pattern'] as List).map((e) => (e as num).toInt()).toList(),
      );
}

/// Sends IR remote codes through the phone's built-in blaster (most phones do
/// not have one) and saves them under a device name ("ac", "tv", "ac 2", ...).
class IrService {
  static const MethodChannel _ch = MethodChannel('com.privateagent/ir');
  static const String _key = 'ir_codes_v1';

  Future<bool> hasEmitter() async {
    try {
      return await _ch.invokeMethod<bool>('hasEmitter') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<List<IrCode>> list() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).map((e) => IrCode.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<IrCode> codes) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(codes.map((c) => c.toJson()).toList()));
  }

  IrCode? _find(List<IrCode> codes, String name) {
    final n = name.trim().toLowerCase();
    for (final c in codes) {
      if (c.name.toLowerCase() == n) return c;
    }
    return null;
  }

  /// Saves/overwrites a code under [name]. Pattern must have an even number of
  /// entries (on, off, on, off, ... in microseconds).
  Future<String> save(String name, int frequency, List<int> pattern) async {
    final n = name.trim();
    if (n.isEmpty) return 'A device name is needed (e.g. "ac", "tv", "ac 2").';
    if (pattern.isEmpty || pattern.length.isOdd) {
      return 'Could not save "$n": the pattern needs an even number of on/off values (microseconds).';
    }
    final codes = await list();
    codes.removeWhere((c) => c.name.toLowerCase() == n.toLowerCase());
    codes.add(IrCode(n, frequency, pattern));
    await _saveAll(codes);
    return 'Saved IR code "$n" (${pattern.length} pulses at ${frequency}Hz).';
  }

  Future<String> remove(String name) async {
    final codes = await list();
    final before = codes.length;
    codes.removeWhere((c) => c.name.toLowerCase() == name.trim().toLowerCase());
    if (codes.length == before) return 'No saved IR code called "$name".';
    await _saveAll(codes);
    return 'Removed "$name".';
  }

  Future<String> send(String name) async {
    if (!await hasEmitter()) {
      return 'This phone has no built-in IR blaster, so it cannot send infrared codes.';
    }
    final codes = await list();
    final c = _find(codes, name);
    if (c == null) {
      final have = codes.map((e) => e.name).join(', ');
      return 'No saved IR code called "$name".${have.isEmpty ? '' : ' Saved codes: $have.'}';
    }
    try {
      await _ch.invokeMethod('transmit', {'frequency': c.frequency, 'pattern': c.pattern});
      return 'Sent "$name".';
    } on PlatformException catch (e) {
      return 'Could not send "$name": ${e.message ?? e.code}';
    } catch (e) {
      return 'Could not send "$name": $e';
    }
  }
}
