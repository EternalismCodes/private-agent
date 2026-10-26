import 'dart:async';
import 'package:flutter/services.dart';

/// "Ears" for a WhatsApp/Telegram call that never touches the microphone:
/// reads the on-screen subtitle window of the phone's own live-captioning
/// (Xiaomi AI Subtitles, Google Live Caption…) through the accessibility
/// service, and turns it into finished sentences spoken by the other person.
///
/// The system captions are produced from the call audio inside Android, so
/// the call app's microphone lock and speaker echo don't matter.
class CaptionEars {
  static const MethodChannel _probe = MethodChannel('com.privateagent/audioprobe');

  static const _captionPkgs = ['aiasst', 'caption', 'subtitle', 'livetranscribe'];

  final void Function(String text) onHeard;
  final Duration settle;
  Timer? _timer;
  String _last = '';
  String _emitted = '';
  DateTime _changedAt = DateTime.now();
  bool _found = false;
  bool _busy = false;

  CaptionEars({required this.onHeard, this.settle = const Duration(milliseconds: 1500)});

  /// True once a caption window has actually been seen.
  bool get found => _found;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ignore everything currently on screen (used right after the agent speaks,
  /// because the captions may pick up the agent's own voice).
  void rebase() {
    _emitted = _last;
    _changedAt = DateTime.now();
  }

  /// Just the subtitle text, without the caption app's buttons and labels.
  static String contentOf(String windowText) {
    final t = windowText.trim();
    const marker = 'Subtitles';
    final i = t.lastIndexOf(marker);
    return (i >= 0 ? t.substring(i + marker.length) : t).trim();
  }

  Future<String?> _readCaptionText() async {
    final windows = await _probe.invokeMethod<List>('dumpWindows');
    if (windows == null) return null;
    for (final w in windows.whereType<Map>()) {
      final id = '${w['pkg'] ?? ''} ${w['title'] ?? ''}'.toLowerCase();
      if (_captionPkgs.any(id.contains)) {
        _found = true;
        return contentOf((w['text'] ?? '').toString());
      }
    }
    return null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final cur = await _readCaptionText();
      if (cur == null) return;
      final now = DateTime.now();
      if (cur != _last) {
        _last = cur;
        _changedAt = now;
        return;
      }
      if (cur.isEmpty || cur == _emitted || now.difference(_changedAt) < settle) return;
      final fresh = _newPart(cur, _emitted);
      _emitted = cur;
      if (fresh.trim().length >= 2) onHeard(fresh.trim());
    } catch (_) {
      // Accessibility not ready yet; try again on the next tick.
    } finally {
      _busy = false;
    }
  }

  /// The words in [cur] that were not already handed over as [done].
  static String _newPart(String cur, String done) {
    if (done.isEmpty) return cur;
    if (cur.startsWith(done)) return cur.substring(done.length);
    final tail = done.length > 24 ? done.substring(done.length - 24) : done;
    final at = cur.lastIndexOf(tail);
    if (at >= 0) return cur.substring(at + tail.length);
    return cur; // captions scrolled on; treat it all as new
  }
}
