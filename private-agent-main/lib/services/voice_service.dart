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
  void Function()? _engineStopped;

  bool get isListening => _isListening;

  /// True once speech recognition is available (microphone permission granted).
  bool get isReady => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;

    unawaited(_preferNaturalVoice());
    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
        _engineStopped?.call();
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') _engineStopped?.call();
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

  /// Listens for one utterance with voice-activity endpointing: it waits for
  /// the person to start talking, keeps listening while they talk (partial
  /// results and sound level count as activity) and only stops after
  /// [endSilence] of quiet. Returns the text, or null when nothing was said.
  Future<String?> listenOnce({
    Duration maxSpeech = const Duration(seconds: 30),
    Duration endSilence = const Duration(milliseconds: 1200),
    Duration noSpeechTimeout = const Duration(seconds: 8),
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return null;
    if (_speech.isListening) await _speech.stop();

    final completer = Completer<String?>();
    _pendingListen = completer;
    _isListening = true;
    final started = DateTime.now();
    var lastWords = '';
    var lastActivity = started;
    var heardSpeech = false;

    void finish() {
      if (completer.isCompleted) return;
      final text = lastWords.trim();
      completer.complete(text.isEmpty ? null : text);
    }

    // Ignore status events fired while the recogniser is still starting.
    _engineStopped = () {
      if (DateTime.now().difference(started).inMilliseconds > 500) finish();
    };

    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (completer.isCompleted) return;
      final now = DateTime.now();
      if (heardSpeech && now.difference(lastActivity) >= endSilence) {
        finish();
      } else if (!heardSpeech && now.difference(started) >= noSpeechTimeout) {
        finish();
      } else if (now.difference(started) >= maxSpeech) {
        finish();
      }
    });

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          final words = result.recognizedWords;
          if (words.trim().isNotEmpty) {
            if (words != lastWords) lastActivity = DateTime.now();
            lastWords = words;
            heardSpeech = true;
          }
          if (result.finalResult) finish();
        },
        // Loud input keeps the turn open through short pauses in a sentence.
        onSoundLevelChange: (double level) {
          if (heardSpeech && level > 4) lastActivity = DateTime.now();
        },
        listenFor: maxSpeech + const Duration(seconds: 5),
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
        ),
      );
    } catch (_) {
      finish();
    }

    final text = await completer.future;
    ticker.cancel();
    _engineStopped = null;
    _isListening = false;
    _pendingListen = null;
    try {
      await _speech.stop();
    } catch (_) {}
    return text;
  }

  /// Best-effort switch to a more natural-sounding installed voice (prefers
  /// network/"neural"-style voices, e.g. Google's, over the terse offline
  /// default). Silently does nothing if the engine doesn't expose voices.
  Future<void> _preferNaturalVoice() async {
    try {
      final dynamic raw = await _tts.getVoices;
      if (raw is! List) return;
      Map? best;
      var bestScore = -1;
      for (final v in raw) {
        if (v is! Map) continue;
        final locale = (v['locale'] ?? '').toString().toLowerCase();
        if (!locale.startsWith('en')) continue;
        final name = (v['name'] ?? '').toString().toLowerCase();
        var score = 0;
        if (v['network'] == true) score += 3;
        if (name.contains('wavenet') || name.contains('neural') || name.contains('studio')) {
          score += 3;
        }
        if (name.contains('local')) score -= 1;
        if (locale == 'en-us') score += 1;
        if (score > bestScore) {
          bestScore = score;
          best = v;
        }
      }
      if (best != null && bestScore > 0 && best['name'] != null) {
        await _tts.setVoice({
          'name': best['name'].toString(),
          'locale': (best['locale'] ?? 'en-US').toString(),
        });
      }
    } catch (_) {
      // Not every engine/platform supports voice selection; system default stays.
    }
  }

  /// Speaks [text] and completes when the speech has finished.
  Future<void> speakAndWait(String text, {double? rate}) async {
    if (text.trim().isEmpty) return;
    try {
      if (rate != null) await _tts.setSpeechRate(rate);
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
