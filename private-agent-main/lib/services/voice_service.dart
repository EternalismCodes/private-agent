import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isListening = false;
  Completer<String?>? _pendingListen;

  bool get isListening => _isListening;

  Future<void> init() async {
    if (_isInitialized) return;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
        final pending = _pendingListen;
        if (pending != null && !pending.isCompleted) pending.complete(null);
      },
    );

    // Configure TTS
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Start listening for speech. Returns transcribed text via callback.
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return;

    _isListening = true;

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          onResult(result.recognizedWords);
          onDone();
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: false,
      ),
    );
  }

  /// Listens for a single utterance and returns the recognised text, or null
  /// when nothing was heard / recognition failed. Used by the voice call.
  Future<String?> listenOnce({
    Duration listenFor = const Duration(seconds: 20),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return null;
    if (_speech.isListening) await _speech.stop();

    final completer = Completer<String?>();
    _pendingListen = completer;
    _isListening = true;

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          if (result.finalResult && !completer.isCompleted) {
            completer.complete(result.recognizedWords);
          }
        },
        listenFor: listenFor,
        pauseFor: pauseFor,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: false,
        ),
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    // Safety net in case the engine never reports a final result.
    final guard = Timer(listenFor + const Duration(seconds: 4), () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final text = await completer.future;
    guard.cancel();
    _isListening = false;
    _pendingListen = null;
    try {
      await _speech.stop();
    } catch (_) {}
    return text;
  }

  /// Speaks [text] and completes when the speech has finished.
  Future<void> speakAndWait(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(text);
    } catch (_) {}
  }

  /// Stop listening
  Future<void> stopListening() async {
    final pending = _pendingListen;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    _isListening = false;
    await _speech.stop();
  }

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
  }

  /// Stop speaking
  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
