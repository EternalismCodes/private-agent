import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/call_background.dart';
import '../services/screen_automation_service.dart';
import '../services/shizuku_service.dart';

/// Finds out, on THIS device, which ways of hearing a WhatsApp/Telegram call
/// actually work, so the "talk on my behalf" mode can be built on the one
/// that does. It only measures loudness — no audio is saved or sent anywhere.
class CallAudioTestScreen extends StatefulWidget {
  const CallAudioTestScreen({super.key});

  @override
  State<CallAudioTestScreen> createState() => _CallAudioTestScreenState();
}

class _SourceResult {
  final String name;
  double rms = 0;
  int peak = 0;
  bool? silenced;
  String? error;
  _SourceResult(this.name);

  bool get heard => error == null && silenced != true && peak > 600 && rms > 120;
}

class _CallAudioTestScreenState extends State<CallAudioTestScreen> {
  static const MethodChannel _probe = MethodChannel('com.privateagent/audioprobe');
  static const _sources = <String, int>{
    'Voice recognition': 6,
    'Microphone': 1,
    'Voice communication': 7,
    'Unprocessed': 9,
  };
  static const _ignorePkgs = ['com.whatsapp', 'org.telegram', 'org.thunderdog', 'com.orailnoor.privateagent', 'com.android.systemui', 'launcher'];

  final ShizukuService _shizuku = ShizukuService();
  bool _running = false;
  String _status = '';
  final Map<String, _SourceResult> _results = {};
  int _audioMode = -1;
  bool _speaker = false;
  final List<String> _captionHints = [];
  final List<String> _shizukuLines = [];
  String _shizukuNote = '';
  bool _accessibilityOn = false;
  bool _done = false;
  bool _cableRunning = false;
  final List<String> _cableLines = [];
  String _cableVerdict = '';

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _done = false;
      _results.clear();
      _captionHints.clear();
      _shizukuLines.clear();
      _shizukuNote = '';
      _status = 'Checking permissions…';
    });

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      setState(() {
        _running = false;
        _status = 'The microphone permission is needed for this test.';
      });
      return;
    }
    _accessibilityOn = await ScreenAutomationService().isServiceRunning();
    final shizukuUp = await _shizuku.checkAvailability();
    if (shizukuUp && !_shizuku.hasPermission) await _shizuku.requestPermission();

    // The foreground service lets the microphone keep working once you switch
    // to the call app.
    await CallBackground.start('Call audio test — switch to your call now', phase: 'listening');
    setState(() => _status = 'Switch to your call now — the test starts in 12 seconds.');
    await CallBackground.minimize();
    for (var s = 12; s > 0; s--) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      await CallBackground.update('Call audio test starts in ${s - 1}s — keep the call on speaker', phase: 'listening');
    }

    final snapshots = <List<Map>>[];
    for (var round = 1; round <= 3; round++) {
      await CallBackground.update('Testing… round $round of 3 — keep the other person talking', phase: 'listening');
      try {
        final st = await _probe.invokeMethod<Map>('audioState');
        if (st != null) {
          _audioMode = (st['mode'] as num?)?.toInt() ?? _audioMode;
          _speaker = st['speakerphone'] == true;
        }
      } catch (_) {}
      for (final e in _sources.entries) {
        final r = _results.putIfAbsent(e.key, () => _SourceResult(e.key));
        try {
          final m = await _probe.invokeMethod<Map>('probeMic', {'source': e.value, 'ms': 1200});
          if (m == null) continue;
          if (m['error'] != null) {
            r.error = m['error'].toString();
            continue;
          }
          final rms = (m['rms'] as num?)?.toDouble() ?? 0;
          final peak = (m['peak'] as num?)?.toInt() ?? 0;
          if (rms > r.rms) r.rms = rms;
          if (peak > r.peak) r.peak = peak;
          final sil = m['silenced'];
          if (sil is bool) r.silenced = (r.silenced ?? false) || sil;
        } catch (e2) {
          r.error = e2.toString();
        }
      }
      try {
        final w = await _probe.invokeMethod<List>('dumpWindows');
        if (w != null) snapshots.add(w.whereType<Map>().toList());
      } catch (_) {}
      if (round == 2 && shizukuUp && _shizuku.hasPermission) {
        await _collectShizuku();
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!shizukuUp) _shizukuNote = 'Shizuku is not running, so the system-level check was skipped.';
    _analyseCaptions(snapshots);

    await CallBackground.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _done = true;
      _status = 'Done.';
    });
  }

  /// Can a Shizuku-launched helper act as a "virtual audio cable" (play the
  /// agent's voice straight into the call app's microphone)? That needs system
  /// audio-routing permissions the shell user may or may not hold. This only
  /// checks; it changes nothing.
  Future<void> _checkCable() async {
    if (_cableRunning) return;
    setState(() {
      _cableRunning = true;
      _cableLines.clear();
      _cableVerdict = '';
    });
    try {
      final up = await _shizukuReady();
      if (!up) {
        _cableVerdict = 'Shizuku is not running or has not been allowed for PrivateAgent.';
        return;
      }
      final sdk = (await _shizuku.runCommand('getprop ro.build.version.sdk')).trim();
      final hyper = (await _shizuku.runCommand('getprop ro.mi.os.version.name')).trim();
      final osv = (await _shizuku.runCommand('getprop ro.mi.os.version.incremental')).trim();
      _cableLines.add('Android SDK $sdk${hyper.isNotEmpty ? ', $hyper $osv' : ''}');

      final pkg = await _shizuku.runCommand('dumpsys package com.android.shell');
      const wanted = [
        'MODIFY_AUDIO_ROUTING',
        'CAPTURE_AUDIO_OUTPUT',
        'CAPTURE_VOICE_COMMUNICATION_OUTPUT',
        'CAPTURE_MEDIA_OUTPUT',
        'MODIFY_AUDIO_SETTINGS',
      ];
      final held = <String, bool>{};
      for (final name in wanted) {
        final line = pkg.split('\n').firstWhere(
              (l) => l.contains('permission.$name') && l.contains('granted='),
              orElse: () => '',
            );
        final granted = line.contains('granted=true');
        held[name] = granted;
        _cableLines.add('$name: ${line.isEmpty ? 'not held by the shell user' : (granted ? 'granted' : 'declared but NOT granted')}');
      }

      final policy = await _shizuku.runCommand('dumpsys media.audio_policy');
      final submix = policy.split('\n').where((l) => l.toLowerCase().contains('submix')).map((l) => l.trim()).take(8).toList();
      _cableLines.add(submix.isEmpty ? 'Remote submix device: not mentioned in the audio policy' : 'Remote submix device: present');
      _cableLines.addAll(submix);

      final routing = held['MODIFY_AUDIO_ROUTING'] == true;
      final capture = held['CAPTURE_AUDIO_OUTPUT'] == true;
      if (routing && capture && submix.isNotEmpty) {
        _cableVerdict =
            'Possible. The shell user holds the audio-routing permissions a virtual cable needs and the loopback device exists. A helper is worth trying, but it is untested and HyperOS may still block it.';
      } else {
        final missing = [
          if (!routing) 'MODIFY_AUDIO_ROUTING',
          if (!capture) 'CAPTURE_AUDIO_OUTPUT',
          if (submix.isEmpty) 'the remote-submix loopback device',
        ];
        _cableVerdict = 'Blocked on this device: missing ${missing.join(', ')}. A Shizuku virtual cable is not possible here.';
      }
    } catch (e) {
      _cableVerdict = 'The check failed: $e';
    } finally {
      if (mounted) setState(() => _cableRunning = false);
    }
  }

  Future<bool> _shizukuReady() async {
    final up = await _shizuku.checkAvailability();
    if (!up) return false;
    if (!_shizuku.hasPermission) return _shizuku.requestPermission();
    return true;
  }

  Future<void> _collectShizuku() async {
    try {
      final out = await _shizuku.runCommand('dumpsys audio');
      final keep = RegExp(r'(silenced|source:|usage=|USAGE_|whatsapp|telegram|capture|AudioPlaybackConfiguration|AudioRecordingConfiguration)', caseSensitive: false);
      for (final line in out.split('\n')) {
        if (keep.hasMatch(line)) _shizukuLines.add(line.trim());
        if (_shizukuLines.length >= 60) break;
      }
      _shizukuNote = _shizukuLines.isEmpty
          ? 'Shizuku ran, but the audio report had nothing relevant.'
          : 'Shizuku read the system audio report during the call (excerpt below).';
    } catch (e) {
      _shizukuNote = 'The Shizuku check failed: $e';
    }
  }

  void _analyseCaptions(List<List<Map>> snaps) {
    if (snaps.isEmpty) {
      _captionHints.add(_accessibilityOn
          ? 'Could not read any windows through the accessibility service.'
          : 'The PrivateAgent accessibility service is off, so Live Caption could not be checked.');
      return;
    }
    // Windows (other than the call app itself) whose text changed between rounds.
    final seen = <String, Set<String>>{};
    for (final snap in snaps) {
      for (final w in snap) {
        final pkg = (w['pkg'] ?? '').toString();
        final text = (w['text'] ?? '').toString().trim();
        if (text.isEmpty || _ignorePkgs.any((p) => pkg.contains(p))) continue;
        seen.putIfAbsent('$pkg | ${w['title'] ?? ''}', () => {}).add(text);
      }
    }
    for (final e in seen.entries) {
      final looksLikeCaption = e.key.toLowerCase().contains('caption');
      if (e.value.length >= 2 || looksLikeCaption) {
        _captionHints.add('${e.key}: "${e.value.last}"');
      }
    }
    if (_captionHints.isEmpty) {
      _captionHints.add('No live-changing caption text was visible. Turn Live Caption on (press a volume key and tap the caption icon) before running the test.');
    }
  }

  String _report() {
    final b = StringBuffer('Call audio test\n');
    b.writeln('audio mode: $_audioMode (2 = in call, 3 = in app call), speakerphone: $_speaker');
    for (final r in _results.values) {
      b.writeln('${r.name}: ${r.error ?? 'rms ${r.rms.toStringAsFixed(0)}, peak ${r.peak}, silenced ${r.silenced}'}');
    }
    b.writeln('Live Caption: ${_captionHints.join(' || ')}');
    b.writeln('Shizuku: $_shizukuNote');
    for (final l in _shizukuLines) {
      b.writeln(l);
    }
    if (_cableLines.isNotEmpty || _cableVerdict.isNotEmpty) {
      b.writeln('\nVirtual cable check: $_cableVerdict');
      for (final l in _cableLines) {
        b.writeln(l);
      }
    }
    return b.toString();
  }

  String _verdict() {
    final working = _results.values.where((r) => r.heard).map((r) => r.name).toList();
    final captions = _captionHints.any((h) => h.contains('"'));
    final parts = <String>[];
    if (working.isNotEmpty) {
      parts.add('The microphone can hear sound during the call through: ${working.join(', ')}. Speakerphone listening should work on this device.');
    } else {
      parts.add('The microphone got silence during the call (Android hands the mic to the call app), so listening through the microphone will not work here.');
    }
    if (captions) parts.add('Live Caption text was readable, so it can be used as the "ears" instead.');
    return parts.join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Call audio test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Checks which ways of hearing a WhatsApp or Telegram call work on this device. No audio is saved or sent anywhere.',
            style: TextStyle(height: 1.4),
          ),
          const SizedBox(height: 12),
          const Text(
            '1. Turn Live Caption on (volume key → caption icon).\n'
            '2. Start a WhatsApp or Telegram call and switch it to speaker.\n'
            '3. Ask the other person to keep talking for about a minute.\n'
            '4. Open PrivateAgent and tap Start. It sends you back to the call; keep the phone still and come back here after the notification says Done.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Virtual cable check (Shizuku)', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(
                    'Checks whether this device lets Shizuku play the agent\'s voice straight into a call app\'s microphone. No call needed; nothing is changed.',
                    style: TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _cableRunning ? null : _checkCable,
                    icon: const Icon(Icons.cable_rounded),
                    label: Text(_cableRunning ? 'Checking…' : 'Run check'),
                  ),
                  if (_cableVerdict.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_cableVerdict, style: const TextStyle(height: 1.4))),
                  for (final l in _cableLines) Padding(padding: const EdgeInsets.only(top: 3), child: Text(l, style: const TextStyle(fontSize: 12))),
                  if (_cableLines.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _report()));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied — paste it to me.')));
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy report'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.graphic_eq_rounded),
            label: Text(_running ? 'Running…' : 'Start test'),
          ),
          if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status)),
          if (_done) ...[
            const SizedBox(height: 16),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(_verdict(), style: const TextStyle(height: 1.4)))),
            const SizedBox(height: 8),
            const Text('Microphone sources', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final r in _results.values)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(r.heard ? Icons.check_circle_rounded : Icons.cancel_rounded, color: r.heard ? Colors.green : Colors.redAccent),
                title: Text(r.name),
                subtitle: Text(r.error ?? 'loudness ${r.rms.toStringAsFixed(0)}, peak ${r.peak}${r.silenced == true ? ', silenced by Android' : ''}'),
              ),
            const SizedBox(height: 8),
            const Text('Live Caption', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final h in _captionHints) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(h, style: const TextStyle(fontSize: 13))),
            const SizedBox(height: 8),
            const Text('Shizuku', style: TextStyle(fontWeight: FontWeight.w700)),
            Text(_shizukuNote, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _report()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied — paste it to me.')));
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy full report'),
            ),
          ],
        ],
      ),
    );
  }
}
