import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'shizuku_service.dart';

/// The virtual audio cable: plays the agent's voice straight into the call
/// app's microphone, so the other person hears it with no speaker, echo or
/// room noise.
///
/// How: a small helper (`CableMain`, inside this app's APK) is started through
/// Shizuku, so it runs as the shell user and may register an Android audio
/// policy. That policy re-routes every microphone recording made by the call
/// apps (WhatsApp, Telegram...) to an AudioTrack the helper owns. This service
/// starts the helper, connects to it on 127.0.0.1 and streams PCM into it.
///
/// Start it BEFORE the call app opens its microphone (i.e. before placing the
/// call): Android decides where a recording comes from when it starts.
class CableService {
  CableService._();
  static final CableService instance = CableService._();

  static const MethodChannel _channel = MethodChannel('com.privateagent/cable');
  static const int _port = 47653;
  static const String _log = '/data/local/tmp/pa_cable.log';

  final ShizukuService _shizuku = ShizukuService();
  Socket? _socket;
  Completer<void>? _playWait;
  Timer? _playTimer;

  /// Why the last [start] failed (empty when it did not).
  String lastError = '';

  bool get active => _socket != null;

  /// Starts the helper and connects. Returns true when the cable is live.
  Future<bool> start() async {
    if (active) return true;
    lastError = '';
    try {
      if (!await _shizuku.checkAvailability()) {
        lastError = 'Shizuku is not running.';
        return false;
      }
      if (!_shizuku.hasPermission && !await _shizuku.requestPermission()) {
        lastError = 'Shizuku has not been allowed for PrivateAgent.';
        return false;
      }
      final info = await _channel.invokeMethod<Map>('info');
      final apk = info?['apk']?.toString() ?? '';
      final uids = <int>[
        for (final v in ((info?['uids'] as Map?)?.values ?? const <dynamic>[])) (v as num).toInt(),
      ];
      if (apk.isEmpty) {
        lastError = 'Could not locate the app package.';
        return false;
      }
      if (uids.isEmpty) {
        lastError = 'No call app (WhatsApp, Telegram) is installed.';
        return false;
      }

      final token = _token();
      // Clear a stale helper, then start a fresh one fully detached from this shell.
      await _shizuku.runCommand('pkill -f com.orailnoor.privateagent.CableMain');
      await _shizuku.runCommand(
        "CLASSPATH='$apk' nohup setsid app_process /system/bin --nice-name=pa_cable "
        'com.orailnoor.privateagent.CableMain $_port $token ${uids.join(',')} '
        '>/dev/null 2>&1 </dev/null &',
      );

      Socket? s;
      for (var i = 0; i < 40 && s == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        try {
          s = await Socket.connect(InternetAddress.loopbackIPv4, _port, timeout: const Duration(seconds: 1));
        } catch (_) {}
      }
      if (s == null) {
        lastError = 'The helper did not start. ${await _helperLog()}';
        return false;
      }
      s.setOption(SocketOption.tcpNoDelay, true);
      s.write('HELLO $token\n');
      await s.flush();
      final first = StringBuffer();
      final reply = Completer<String>();
      final sub = s.listen(
        (data) {
          first.write(String.fromCharCodes(data));
          if (first.toString().contains('\n') && !reply.isCompleted) reply.complete(first.toString().trim());
        },
        onDone: () {
          if (!reply.isCompleted) reply.complete(first.toString().trim());
          _drop();
        },
        onError: (_) => _drop(),
        cancelOnError: true,
      );
      final line = await reply.future.timeout(const Duration(seconds: 10), onTimeout: () => '');
      if (!line.startsWith('OK')) {
        await sub.cancel();
        s.destroy();
        lastError = line.startsWith('ERR') ? line.substring(3).trim() : 'The helper did not answer. ${await _helperLog()}';
        return false;
      }
      _socket = s;
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  static String _token() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<String> _helperLog() async {
    final out = (await _shizuku.runCommand('tail -n 6 $_log')).trim();
    return out.isEmpty ? '(no helper log)' : out;
  }

  void _drop() {
    _socket = null;
    _finishPlay();
  }

  void _finishPlay() {
    _playTimer?.cancel();
    _playTimer = null;
    final w = _playWait;
    _playWait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _frame(int type, [Uint8List? payload]) {
    final s = _socket;
    if (s == null) return;
    final len = payload?.length ?? 0;
    final head = ByteData(5)
      ..setUint8(0, type)
      ..setUint32(1, len, Endian.big);
    s.add(head.buffer.asUint8List());
    if (payload != null) s.add(payload);
  }

  /// Plays mono float samples into the call and completes when they have been
  /// heard (or [flush] was called).
  Future<void> playFloat(Float32List samples, int sampleRate) {
    final pcm = Uint8List(samples.length * 2);
    final bd = ByteData.view(pcm.buffer);
    for (var i = 0; i < samples.length; i++) {
      bd.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return playPcm16(pcm, sampleRate);
  }

  /// [pcm] is 16-bit little-endian mono.
  Future<void> playPcm16(Uint8List pcm, int sampleRate) async {
    if (!active || pcm.isEmpty) return;
    _finishPlay();
    // Cap one frame at about 20 s of audio.
    final payload = BytesBuilder(copy: false)
      ..add((ByteData(4)..setUint32(0, sampleRate, Endian.big)).buffer.asUint8List())
      ..add(pcm);
    _frame(0x50, payload.toBytes()); // 'P'
    final wait = Completer<void>();
    _playWait = wait;
    final ms = pcm.length * 1000 ~/ (2 * sampleRate);
    _playTimer = Timer(Duration(milliseconds: ms + 250), _finishPlay);
    await wait.future;
  }

  /// Speech already queued in the cable is dropped (the agent was interrupted).
  void flush() {
    _frame(0x46); // 'F'
    _finishPlay();
  }

  Future<void> stop() async {
    final s = _socket;
    if (s != null) {
      try {
        _frame(0x51); // 'Q'
        await s.flush();
      } catch (_) {}
      try {
        s.destroy();
      } catch (_) {}
    }
    _drop();
    try {
      await _shizuku.runCommand('pkill -f com.orailnoor.privateagent.CableMain');
    } catch (_) {}
  }

  /// Reads a 16-bit PCM WAV (what Android's own TTS writes) and plays it.
  Future<bool> playWavFile(String path) async {
    try {
      final b = await File(path).readAsBytes();
      if (b.length < 44) return false;
      final bd = ByteData.sublistView(b);
      var pos = 12;
      int rate = 22050, channels = 1, bits = 16;
      int? dataAt, dataLen;
      while (pos + 8 <= b.length) {
        final id = String.fromCharCodes(b.sublist(pos, pos + 4));
        final size = bd.getUint32(pos + 4, Endian.little);
        if (id == 'fmt ') {
          channels = bd.getUint16(pos + 10, Endian.little);
          rate = bd.getUint32(pos + 12, Endian.little);
          bits = bd.getUint16(pos + 22, Endian.little);
        } else if (id == 'data') {
          dataAt = pos + 8;
          dataLen = min(size, b.length - dataAt);
          break;
        }
        pos += 8 + size + (size & 1);
      }
      if (dataAt == null || dataLen == null || bits != 16 || channels < 1) return false;
      final frames = dataLen ~/ (2 * channels);
      final mono = Uint8List(frames * 2);
      final out = ByteData.view(mono.buffer);
      for (var i = 0; i < frames; i++) {
        out.setInt16(i * 2, bd.getInt16(dataAt + i * 2 * channels, Endian.little), Endian.little);
      }
      await playPcm16(mono, rate);
      return true;
    } catch (_) {
      return false;
    }
  }
}
