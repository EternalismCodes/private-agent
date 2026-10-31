import 'dart:async';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../agent/prefs.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'cable_service.dart';
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

    var restarting = false;

    Future<void> begin() async {
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
    }

    // Android's recogniser ends itself after a few quiet seconds. If nothing
    // was said yet, quietly start it again instead of returning, so a call
    // is one continuous listening session (the start beep is muted).
    _engineStopped = () {
      if (completer.isCompleted) return;
      if (DateTime.now().difference(started).inMilliseconds <= 500) return; // still starting
      if (heardSpeech || DateTime.now().difference(started) >= noSpeechTimeout) {
        finish();
        return;
      }
      if (restarting) return;
      restarting = true;
      Future<void>.delayed(const Duration(milliseconds: 120), () async {
        try {
          if (!completer.isCompleted) await begin();
        } catch (_) {
          finish();
        } finally {
          restarting = false;
        }
      });
    };

    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (completer.isCompleted) return;
      final now = DateTime.now();
      if (heardSpeech && now.difference(lastActivity) >= endSilence) {
        finish();
      } else if (!heardSpeech && now.difference(started) >= noSpeechTimeout) {
        finish();
      } else if (now.difference(started) >= maxSpeech && heardSpeech) {
        finish();
      }
    });

    try {
      await begin();
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
  /// While talk mode is on, only talk mode may speak: the agent's own chat
  /// replies must never be played into the call.
  static bool talkLock = false;

  static Future<void> _tail = Future<void>.value();
  static int _speechGen = 0;
  static String _lastSpoken = '';
  static DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _enqueue(Future<void> Function() job) {
    final run = _tail.then((_) => job()).catchError((_) {});
    _tail = run;
    return run;
  }

  /// Plays one utterance. On a call with the virtual cable live, [wav] is the
  /// already-rendered speech (see [_synthQueued]) and goes into the call;
  /// otherwise the system voice speaks aloud.
  Future<void> _utter(String text, {double? rate, Future<String?>? wav}) async {
    if (wav != null && CableService.instance.active) {
      final path = await wav.timeout(const Duration(seconds: 9), onTimeout: () => null);
      if (path != null) {
        final ok = await CableService.instance.playWavFile(path);
        try {
          await File(path).delete();
        } catch (_) {}
        if (ok) return;
      }
    }
    try {
      await _tts.stop(); // make sure nothing else is playing
    } catch (_) {}
    try {
      await _applyVoiceFor(text);
      if (rate != null) await _tts.setSpeechRate(rate);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak(text).timeout(const Duration(seconds: 25), onTimeout: () {});
    } catch (_) {}
  }

  // Rendering to a file is serialised (one engine), but runs ahead of playback,
  // so the next sentence is ready while the previous one is still playing.
  static Future<void> _synthChain = Future<void>.value();

  Future<String?> _synthQueued(String text, double? rate) {
    final c = Completer<String?>();
    _synthChain = _synthChain.then((_) async {
      try {
        c.complete(await _synthToFile(text, rate).timeout(const Duration(seconds: 7), onTimeout: () => null));
      } catch (_) {
        if (!c.isCompleted) c.complete(null);
      }
    });
    return c.future;
  }

  Future<String?> _synthToFile(String text, double? rate) async {
    try {
      await _applyVoiceFor(text);
      if (rate != null) await _tts.setSpeechRate(rate);
      await _tts.awaitSynthCompletion(true);
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/cable_${DateTime.now().microsecondsSinceEpoch}.wav';
      await _tts.synthesizeToFile(text, path, true);
      return await File(path).exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Speaks [text] after anything already being said, and completes when it
  /// has finished (used for call replies, sentence by sentence).
  Future<void> speakAndWait(String text, {double? rate, bool onCall = false}) {
    final clean = text.trim();
    if (clean.isEmpty || (talkLock && !onCall)) return Future<void>.value();
    final gen = _speechGen;
    // On a call, start rendering this sentence now, while earlier ones are
    // still playing, so there is no silent gap between sentences.
    final wav = (onCall && CableService.instance.active) ? _synthQueued(clean, rate) : null;
    return _enqueue(() async {
      if (gen != _speechGen) {
        final p = await wav;
        if (p != null) {
          try {
            await File(p).delete();
          } catch (_) {}
        }
        return; // stopped or replaced while waiting
      }
      await _utter(clean, rate: rate, wav: wav);
    });
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
    if (clean.isEmpty || talkLock) return;
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
    if (CableService.instance.active) CableService.instance.flush();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
