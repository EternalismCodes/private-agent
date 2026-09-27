import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Controls the native duty-cycled wake-word listener (see HotwordService.kt
/// for how it avoids holding the microphone open, and how it pauses itself
/// around camera/video-call apps). Runs on Vosk — free, fully offline,
/// Apache-2.0, no account or usage limits — so the wake phrase can be
/// literally anything typed here, not a fixed built-in word list. The first
/// time it's turned on, it downloads a small (~40MB) speech model once;
/// everything after that runs on-device with no network needed.
class HotwordService {
  static const MethodChannel _channel = MethodChannel('com.privateagent/hotword');

  Future<String> get wakePhrase async => (await SharedPreferences.getInstance()).getString('hotword_phrase') ?? 'hey agent';
  Future<int> get listenMs async => (await SharedPreferences.getInstance()).getInt('hotword_listen_ms') ?? 2000;
  Future<int> get idleMs async => (await SharedPreferences.getInstance()).getInt('hotword_idle_ms') ?? 2500;
  Future<bool> get enabled async => (await SharedPreferences.getInstance()).getBool('hotword_enabled') ?? false;

  Future<void> _saveConfig(String phrase, int listenMs, int idleMs, bool enabled) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('hotword_phrase', phrase);
    await p.setInt('hotword_listen_ms', listenMs);
    await p.setInt('hotword_idle_ms', idleMs);
    await p.setBool('hotword_enabled', enabled);
  }

  /// Starts listening for [phrase] (any short phrase — "hey agent", "computer",
  /// whatever's comfortable to say; it's matched as spoken text, not a
  /// trained keyword model). [listenMs]/[idleMs] control the duty cycle —
  /// how long it listens vs. how long it fully releases the mic between
  /// listens. Shorter listen / longer idle = less mic time and less battery,
  /// at the cost of occasionally needing to repeat the phrase.
  Future<String?> start({
    required String phrase,
    int listenMs = 2000,
    int idleMs = 2500,
  }) async {
    final p = phrase.trim();
    if (p.isEmpty) return 'Pick a wake phrase first (e.g. "hey agent").';
    try {
      await _channel.invokeMethod('start', {
        'wakePhrase': p,
        'listenMs': listenMs,
        'idleMs': idleMs,
      });
      await _saveConfig(p, listenMs, idleMs, true);
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
    final cfg = await Future.wait([wakePhrase, listenMs, idleMs]);
    await _saveConfig(cfg[0] as String, cfg[1] as int, cfg[2] as int, false);
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
