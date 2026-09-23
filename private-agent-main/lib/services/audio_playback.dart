import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Native bridge that plays a WAV clip and completes once playback finishes.
/// Used to play audio synthesized by an external TTS server during calls —
/// flutter_tts only drives the OS voice engine, it can't play arbitrary
/// audio bytes.
class AudioPlayback {
  AudioPlayback._();
  static const MethodChannel _channel = MethodChannel('com.privateagent/audio_playback');

  /// Plays [bytes] (WAV) and returns true once playback finished cleanly.
  static Future<bool> playAndWait(Uint8List bytes) async {
    try {
      final ok = await _channel.invokeMethod<bool>('playAndWait', {'bytes': bytes});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
