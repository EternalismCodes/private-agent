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

  /// Sends several saved codes back to back, [gap] apart (default 0.2 s).
  /// An entry may carry a repeat count: "tv power x2" or "tv volume up*3".
  Future<String> sendMany(List<String> names, {Duration gap = const Duration(milliseconds: 200)}) async {
    final jobs = <String>[];
    for (final raw in names) {
      final m = RegExp(r'^(.*?)\s*[x*×]\s*(\d{1,2})$', caseSensitive: false).firstMatch(raw.trim());
      final n = m != null ? m.group(1)!.trim() : raw.trim();
      final times = m != null ? int.parse(m.group(2)!) : 1;
      if (n.isEmpty) continue;
      for (var i = 0; i < times; i++) {
        jobs.add(n);
      }
    }
    if (jobs.isEmpty) return 'No IR command names were given.';
    if (jobs.length == 1) return send(jobs.first);
    final results = <String>[];
    for (var i = 0; i < jobs.length; i++) {
      if (i > 0) await Future.delayed(gap);
      results.add(await send(jobs[i]));
    }
    final failed = results.where((r) => !r.startsWith('Sent ')).toList();
    if (failed.isEmpty) return 'Sent ${jobs.length} IR commands (${jobs.join(', ')}), 0.2s apart.';
    return 'Sent ${jobs.length - failed.length}/${jobs.length} IR commands. Problems: ${failed.join(' ')}';
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
