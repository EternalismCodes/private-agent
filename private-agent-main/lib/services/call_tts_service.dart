import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'audio_playback.dart';
import 'voice_service.dart';

/// Speaks call replies, preferring a more natural voice when one is set up.
///
/// When a Piper-compatible HTTP TTS server is configured, its audio is used;
/// otherwise (and whenever the server fails) this falls back to the on-device
/// system voice, so a call is never left silent.
///
/// Server contract — matches Piper's own reference `http_server.py`: the
/// utterance is POSTed as the raw request body (`text/plain`) to [endpoint];
/// any 200 response is treated as a WAV clip and played. A self-hosted Piper
/// server started with `python3 http_server.py --model <voice>.onnx` speaks
/// this out of the box; point [endpoint] at `http://<host>:<port>/`.
class CallTtsService {
  final VoiceService system;
  String endpoint;

  CallTtsService(this.system, {this.endpoint = ''});

  bool get usingExternalVoice => endpoint.trim().isNotEmpty;

  Future<void> speak(String text, {double systemRate = 0.58}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (!usingExternalVoice) {
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
      // Fall through to the system voice below.
    }
    await system.speakAndWait(clean, rate: systemRate);
  }

  Future<void> stop() async {
    await system.stopSpeaking();
    await AudioPlayback.stop();
  }
}
