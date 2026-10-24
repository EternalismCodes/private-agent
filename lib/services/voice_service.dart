import 'dart:async';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../agent/prefs.dart';
import 'neural_tts.dart';
import 'tts_voices.dart';

class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  String _voiceLang = ''; // 'en' / 'hi' — which voice is currently applied
  static const MethodChannel _sysSound = MethodChannel('com.privateagent/systemsound');

  /// Silences the recognizer's start-of-listening beep so calls feel like
  /// calls (it restarts listening every few seconds).
  Future<void> _muteBeep() async {
    try {
      await _sysSound.invokeMethod('muteBeepBriefly', {'ms': 1200});
    } catch (_) {}
  }
  bool _isInitialized = false;
  bool _isListening = false;
  Completer<String?>? _pendingListen;
  void Function()? _engineStopped;

  bool get isListening => _isListening;

  /// True once speech recognition is available (microphone permission granted).
  bool get isReady => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;

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
    await _applyVoiceFor('hello');
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

    await _muteBeep();
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
      await _muteBeep();
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

  /// Forget which voice is applied so the next utterance re-selects it
  /// (call after the user changes the voice in preferences).
  void invalidateVoice() => _voiceLang = '';

  /// Picks the Hindi or English voice to match [text] (the user's chosen
  /// voice from preferences, else the best installed one), so replies in
  /// either language sound natural without any extra setup.
  Future<void> _applyVoiceFor(String text) async {
    final lang = TtsVoiceCatalog.looksHindi(text) ? 'hi' : 'en';
    if (lang == _voiceLang) return;
    try {
      final prefs = AgentPrefs.instance;
      final chosen = lang == 'hi' ? prefs.ttsHindiVoice : prefs.ttsEnglishVoice;
      final voices = await TtsVoiceCatalog.list(_tts, lang);
      TtsVoice? pick;
      if (chosen.isNotEmpty) {
        for (final v in voices) {
          if (v.name == chosen) pick = v;
        }
      }
      pick ??= voices.isNotEmpty ? voices.first : null;
      if (pick != null) {
        await _tts.setVoice({'name': pick.name, 'locale': pick.locale});
      } else {
        await _tts.setLanguage(lang == 'hi' ? 'hi-IN' : 'en-US');
      }
      _voiceLang = lang;
    } catch (_) {
      // Engine without voice selection: system default stays.
    }
  }

  // ── One voice at a time ────────────────────────────────────────────────
  // All speech (chat replies and calls, natural or system voice) goes through
  // one shared queue, so two utterances can never play over each other.
  static Future<void> _tail = Future<void>.value();
  static int _speechGen = 0;
  static String _lastSpoken = '';
  static DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _enqueue(Future<void> Function() job) {
    final run = _tail.then((_) => job()).catchError((_) {});
    _tail = run;
    return run;
  }

  /// Plays one utterance with the chosen engine; never both at once.
  Future<void> _utter(String text, {double? rate}) async {
    try {
      await _tts.stop(); // make sure the system voice is silent first
    } catch (_) {}
    if (await _speakNeural(text, rate: rate)) return;
    await NeuralTts.instance.stop(); // and the natural voice, before falling back
    try {
      await _applyVoiceFor(text);
      if (rate != null) await _tts.setSpeechRate(rate);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(text);
    } catch (_) {}
  }

  /// Speaks [text] after anything already being said, and completes when it
  /// has finished (used for call replies, sentence by sentence).
  Future<void> speakAndWait(String text, {double? rate}) {
    final clean = text.trim();
    if (clean.isEmpty) return Future<void>.value();
    final gen = _speechGen;
    return _enqueue(() async {
      if (gen != _speechGen) return; // stopped or replaced while waiting
      await _utter(clean, rate: rate);
    });
  }

  /// Built-in natural voice; false means "use the system voice instead".
  Future<bool> _speakNeural(String text, {double? rate}) async {
    if (AgentPrefs.instance.ttsEngine != 'neural') return false;
    final speed = rate == null ? 1.0 : (rate / 0.5).clamp(0.7, 1.5).toDouble();
    return NeuralTts.instance.speak(text, speed: speed);
  }

  /// Stop listening
  Future<void> stopListening() async {
    final pending = _pendingListen;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    _isListening = false;
    await _speech.stop();
  }

  /// Speak text aloud (fire-and-forget). Replaces anything currently being
  /// said, and ignores an identical request made a moment ago.
  Future<void> speak(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final now = DateTime.now();
    if (clean == _lastSpoken && now.difference(_lastSpokenAt) < const Duration(seconds: 4)) return;
    _lastSpoken = clean;
    _lastSpokenAt = now;
    await stopSpeaking();
    final gen = _speechGen;
    await _enqueue(() async {
      if (gen != _speechGen) return;
      await _utter(clean);
    });
  }

  /// Stop speaking (and drop anything still waiting to be spoken).
  Future<void> stopSpeaking() async {
    _speechGen++;
    await NeuralTts.instance.stop();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
