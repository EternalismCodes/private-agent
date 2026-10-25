import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_voices.dart';

/// Built-in natural-sounding offline voices (Piper neural voices, English
/// "Lessac" and Hindi "Pratham") run through the official k2-fsa `sherpa_onnx`
/// Flutter package. Everything is bundled in the app and runs on-device:
/// no server, no download, nothing sent anywhere.
///
/// Synthesis happens in its own isolate so the UI never stalls. If anything
/// fails, [speak] returns false and the caller uses the phone's own voice.
/// A crash guard also switches this engine off after two interrupted attempts
/// in a row, so a device-specific native problem can never become a crash loop.
class NeuralTts {
  NeuralTts._();
  static final NeuralTts instance = NeuralTts._();

  static const _kGuard = 'neural_tts_guard';
  static const _kStrikes = 'neural_tts_strikes';
  static const _kDisabled = 'neural_tts_disabled';
  static const _assetFiles = <String>[
    'en.onnx',
    'en_tokens.txt',
    'hi.onnx',
    'hi_tokens.txt',
    'espeak-ng-data/intonations',
    'espeak-ng-data/phondata',
    'espeak-ng-data/phondata-manifest',
    'espeak-ng-data/phonindex',
    'espeak-ng-data/phontab',
    'espeak-ng-data/en_dict',
    'espeak-ng-data/hi_dict',
    'espeak-ng-data/lang/gmw/en',
    'espeak-ng-data/lang/gmw/en-US',
    'espeak-ng-data/lang/inc/hi',
  ];

  bool _disabled = false;
  bool _guardChecked = false;
  String? _dir;
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  final Map<int, Completer<Map>> _pending = {};
  int _nextId = 0;
  int _ticket = 0;
  Completer<void>? _starting;
  AudioPlayer? _player;

  /// False once the crash guard has switched the neural voice off.
  bool get isDisabled => _disabled;

  /// Call once at app start: detects a previous interrupted synthesis.
  Future<void> checkGuard() async {
    if (_guardChecked) return;
    _guardChecked = true;
    try {
      final p = await SharedPreferences.getInstance();
      var strikes = p.getInt(_kStrikes) ?? 0;
      if (p.getBool(_kGuard) == true) {
        strikes++;
        await p.setInt(_kStrikes, strikes);
        await p.setBool(_kGuard, false);
      }
      _disabled = (p.getBool(_kDisabled) ?? false) || strikes >= 2;
      if (_disabled) await p.setBool(_kDisabled, true);
    } catch (_) {}
  }

  /// Lets the user try the neural voice again after the guard disabled it.
  Future<void> reenable() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kStrikes, 0);
    await p.setBool(_kGuard, false);
    await p.setBool(_kDisabled, false);
    _disabled = false;
  }

  Future<String> _ensureFiles() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/neural-voices-v1');
    final marker = File('${dir.path}/.complete');
    if (!await marker.exists()) {
      if (await dir.exists()) await dir.delete(recursive: true);
      for (final name in _assetFiles) {
        final data = await rootBundle.load('assets/voices/$name');
        final out = File('${dir.path}/$name');
        await out.create(recursive: true);
        await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      await marker.writeAsString('ok');
    }
    return _dir = dir.path;
  }

  Future<void> _startWorker() async {
    if (_toWorker != null) return;
    final pending = _starting;
    if (pending != null) return pending.future;
    final c = _starting = Completer<void>();
    try {
      final rp = ReceivePort();
      final ready = Completer<SendPort>();
      rp.listen((msg) {
        if (msg is SendPort) {
          if (!ready.isCompleted) ready.complete(msg);
        } else if (msg is Map) {
          _pending.remove(msg['id'])?.complete(msg);
        }
      });
      _fromWorker = rp;
      _isolate = await Isolate.spawn(_worker, rp.sendPort);
      _toWorker = await ready.future.timeout(const Duration(seconds: 10));
      c.complete();
    } catch (e) {
      c.completeError(e);
      _toWorker = null;
      rethrow;
    } finally {
      _starting = null;
    }
  }

  /// Speaks [text]; resolves true if it was spoken (or superseded by newer
  /// speech) and false if the caller should fall back to the system voice.
  Future<bool> speak(String text, {double speed = 1.0}) async {
    final clean = text.trim();
    if (clean.isEmpty) return true;
    await checkGuard();
    if (_disabled) return false;
    final ticket = ++_ticket;
    var started = false;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      // If the app dies inside native code, this stays set and the next
      // launch counts a strike (see [checkGuard]).
      await prefs.setBool(_kGuard, true);
      final dir = await _ensureFiles();
      await _startWorker();
      final id = _nextId++;
      final done = Completer<Map>();
      _pending[id] = done;
      _toWorker!.send({
        'id': id,
        'dir': dir,
        'lang': TtsVoiceCatalog.looksHindi(clean) ? 'hi' : 'en',
        'text': clean,
        'speed': speed.clamp(0.6, 1.6),
      });
      final reply = await done.future.timeout(const Duration(seconds: 60));
      await prefs.setBool(_kGuard, false);
      if (reply['error'] != null) return false;
      await prefs.setInt(_kStrikes, 0);
      if (ticket != _ticket) return true; // newer speech replaced this one
      final samples = (reply['samples'] as TransferableTypedData).materialize().asFloat32List();
      final rate = reply['sr'] as int;
      if (samples.isEmpty || rate <= 0) return false;
      final wav = File('$dir/utterance_$ticket.wav');
      await wav.writeAsBytes(_toWav(samples, rate), flush: true);
      if (ticket != _ticket) return true;
      started = true;
      await _play(wav.path, Duration(milliseconds: samples.length * 1000 ~/ rate), ticket);
      _cleanOld(dir, ticket);
      return true;
    } catch (_) {
      try {
        await prefs?.setBool(_kGuard, false);
      } catch (_) {}
      // If audio already began, don't let the caller also speak with the
      // system voice (that would be two voices at once).
      return started;
    }
  }

  // Every utterance gets its own file name: the audio player remembers the last
  // file it was given and can replay stale audio when the name repeats.
  void _cleanOld(String dir, int keepTicket) {
    try {
      for (final f in Directory(dir).listSync()) {
        final n = f.path.split('/').last;
        if (n.startsWith('utterance_') && n != 'utterance_$keepTicket.wav') {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  Future<void> _play(String path, Duration length, int ticket) async {
    final player = _player ??= AudioPlayer();
    await player.stop();
    final finished = player.onPlayerComplete.first;
    await player.play(DeviceFileSource(path));
    if (ticket != _ticket) return;
    await finished.timeout(length + const Duration(seconds: 3), onTimeout: () {});
  }

  Future<void> stop() async {
    _ticket++;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  static Uint8List _toWav(Float32List samples, int sampleRate) {
    final dataLen = samples.length * 2;
    final b = ByteData(44 + dataLen);
    void tag(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + dataLen, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    b.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// Runs in its own isolate: owns the sherpa-onnx engines and does the heavy
/// synthesis away from the UI thread.
void _worker(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  sherpa.initBindings();
  final engines = <String, sherpa.OfflineTts>{};
  inbox.listen((msg) {
    final m = msg as Map;
    final id = m['id'];
    try {
      final lang = m['lang'] as String;
      final dir = m['dir'] as String;
      final tts = engines[lang] ??= sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: '$dir/$lang.onnx',
              tokens: '$dir/${lang}_tokens.txt',
              dataDir: '$dir/espeak-ng-data',
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        ),
      );
      final audio = tts.generate(text: m['text'] as String, sid: 0, speed: (m['speed'] as num).toDouble());
      toMain.send({
        'id': id,
        'sr': audio.sampleRate,
        'samples': TransferableTypedData.fromList([audio.samples]),
      });
    } catch (e) {
      toMain.send({'id': id, 'error': e.toString()});
    }
  });
}
