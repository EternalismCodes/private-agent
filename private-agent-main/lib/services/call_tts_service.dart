import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'audio_playback.dart';
import 'voice_service.dart';

/// Speaks call replies, preferring a more natural voice when one is
/// available.
///
/// [system] (VoiceService) already prefers the bundled on-device neural
/// voice (Piper via sherpa-onnx — no server, no network call) and falls
/// back to the phone's system voice on its own, so that's what this uses by
/// default. If [endpoint] is set, it's an escape hatch for anyone who wants
/// to point at their own self-hosted Piper HTTP server (matching Piper's
/// own reference `http_server.py`: the utterance is POSTed as the raw
/// request body to [endpoint] and any 200 response is treated as a WAV
/// clip) instead of the bundled voice — but this is entirely optional now,
/// nothing needs to be running for calls to have a natural voice.
class CallTtsService {
  final VoiceService system;
  String endpoint;

  CallTtsService(this.system, {this.endpoint = ''});

  bool get usingExternalVoice => endpoint.trim().isNotEmpty;

  Future<void> speak(String text, {double systemRate = 0.58}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    if (!usingExternalVoice) {
      // system.speakAndWait already tries the on-device neural voice first
      // and only falls back to the OS voice if that isn't set up.
      await system.speakAndWait(clean, rate: systemRate);
      return;
    }

    try {
      final response = await http
          .post(
            Uri.parse(endpoint.trim()),
            headers: {'Content-Type': 'text/plain; charset=utf-8'},
            body: clean,
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200 && response.bodyBytes.length > 44) {
        final played = await AudioPlayback.playAndWait(Uint8List.fromList(response.bodyBytes));
        if (played) return;
      }
    } catch (_) {
      // Fall through to the on-device/system voice below.
    }
    await system.speakAndWait(clean, rate: systemRate);
  }

  Future<void> stop() async {
    await system.stopSpeaking();
    await AudioPlayback.stop();
  }
}
