import 'dart:convert';
import 'package:flutter/services.dart';

/// Native bridge for the experimental features (screenshots, teach recording/replay).
class LabChannel {
  LabChannel._();
  static const MethodChannel _ch = MethodChannel('com.privateagent/lab');
  static void Function(String json)? onStopped;
  static bool _init = false;

  static void _ensure() {
    if (_init) return;
    _init = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'recStopped') onStopped?.call('${call.arguments}');
      return null;
    });
  }

  static Future<Map<String, dynamic>?> screenshot({int maxSide = 1280, int quality = 65}) async {
    _ensure();
    try {
      final r = await _ch.invokeMethod('screenshot', {'maxSide': maxSide, 'quality': quality});
      if (r is Map) return Map<String, dynamic>.from(r);
    } catch (_) {}
    return null;
  }

  static Future<bool> recStart(String pkg) async {
    _ensure();
    try {
      return await _ch.invokeMethod<bool>('recStart', {'pkg': pkg}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> recStop() async {
    _ensure();
    try {
      return await _ch.invokeMethod<String>('recStop') ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  static Future<bool> recActive() async {
    _ensure();
    try {
      return await _ch.invokeMethod<bool>('recActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> replayClick(Map<String, dynamic> step, String? match) async {
    try {
      return await _ch.invokeMethod<bool>('replayClick', {'step': jsonEncode(step), 'match': match}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> replayType(Map<String, dynamic> step, String text) async {
    try {
      return await _ch.invokeMethod<bool>('replayType', {'step': jsonEncode(step), 'text': text}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> replayEnter() async {
    try {
      return await _ch.invokeMethod<bool>('replayEnter') ?? false;
    } catch (_) {
      return false;
    }
  }
}
