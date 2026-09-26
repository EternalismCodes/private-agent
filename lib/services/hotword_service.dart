import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Picovoice's free built-in wake words (no training needed — a custom
/// phrase like "Hey Agent" requires training a model on console.picovoice.ai
/// and isn't something this app can generate on its own).
const List<String> kBuiltInWakeWords = [
  'PORCUPINE', 'COMPUTER', 'JARVIS', 'ALEXA', 'AMERICANO', 'BLUEBERRY',
  'BUMBLEBEE', 'GRAPEFRUIT', 'GRASSHOPPER', 'PICOVOICE', 'TERMINATOR',
];

/// Controls the native duty-cycled wake-word listener (see HotwordService.kt
/// for how it avoids holding the microphone open, and how it pauses itself
/// around camera/video-call apps).
class HotwordService {
  static const MethodChannel _channel = MethodChannel('com.privateagent/hotword');

  Future<String?> get accessKey async => (await SharedPreferences.getInstance()).getString('hotword_access_key');
  Future<String> get keyword async => (await SharedPreferences.getInstance()).getString('hotword_keyword') ?? 'PORCUPINE';
  Future<int> get listenMs async => (await SharedPreferences.getInstance()).getInt('hotword_listen_ms') ?? 1500;
  Future<int> get idleMs async => (await SharedPreferences.getInstance()).getInt('hotword_idle_ms') ?? 2500;
  Future<bool> get enabled async => (await SharedPreferences.getInstance()).getBool('hotword_enabled') ?? false;

  Future<void> _saveConfig(String accessKey, String keyword, int listenMs, int idleMs, bool enabled) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('hotword_access_key', accessKey);
    await p.setString('hotword_keyword', keyword);
    await p.setInt('hotword_listen_ms', listenMs);
    await p.setInt('hotword_idle_ms', idleMs);
    await p.setBool('hotword_enabled', enabled);
  }

  /// Starts listening. [listenMs]/[idleMs] control the duty cycle — how long
  /// it listens vs. how long it fully releases the mic between listens.
  /// Shorter listen / longer idle = less mic time and less battery, at the
  /// cost of occasionally needing to repeat the wake word.
  Future<String?> start({
    required String accessKey,
    String keyword = 'PORCUPINE',
    int listenMs = 1500,
    int idleMs = 2500,
  }) async {
    if (accessKey.trim().isEmpty) return 'A Picovoice AccessKey is required (free, from console.picovoice.ai).';
    try {
      await _channel.invokeMethod('start', {
        'accessKey': accessKey.trim(),
        'keyword': keyword,
        'listenMs': listenMs,
        'idleMs': idleMs,
      });
      await _saveConfig(accessKey.trim(), keyword, listenMs, idleMs, true);
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
    final cfg = await Future.wait([accessKey, keyword, listenMs, idleMs]);
    await _saveConfig((cfg[0] as String?) ?? '', cfg[1] as String, cfg[2] as int, cfg[3] as int, false);
  }

  Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Call on app start and app resume: true means the wake word just fired
  /// and brought the app to the front, so the caller should drop straight
  /// into listening (Auto mode voice input), same as tapping the mic.
  Future<bool> consumePendingWake() async {
    try {
      return await _channel.invokeMethod<bool>('consumePendingWake') ?? false;
    } catch (_) {
      return false;
    }
  }
}
