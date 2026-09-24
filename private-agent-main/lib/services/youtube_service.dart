import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:http/http.dart' as http;
import 'screen_automation_service.dart';

/// "Play the top result": looks up the real video id from YouTube's search
/// page and opens it straight in the YouTube app (no tapping needed). If that
/// fails it falls back to tapping the Nth result through accessibility.
class YoutubeService {
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static final RegExp _card = RegExp(r'"videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})"');
  static final RegExp _any = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"');
  static final RegExp _title = RegExp(r'"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"');

  Future<List<({String id, String title})>> _search(String q) async {
    final r = await http.get(
      Uri.parse('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}&hl=en'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'CONSENT=YES+1; SOCS=CAI',
      },
    ).timeout(const Duration(seconds: 12));
    final body = r.body;
    var matches = _card.allMatches(body).toList();
    if (matches.isEmpty) matches = _any.allMatches(body).toList();
    final seen = <String>{};
    final out = <({String id, String title})>[];
    for (final m in matches) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      final end = m.end + 700 > body.length ? body.length : m.end + 700;
      final t = _title.firstMatch(body.substring(m.end, end))?.group(1) ?? '';
      out.add((id: id, title: t.replaceAll(r'\u0026', '&').replaceAll(r'\"', '"')));
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<bool> _open(String url, {bool inApp = true}) async {
    for (final pkg in [if (inApp) 'com.google.android.youtube', null]) {
      try {
        await AndroidIntent(action: 'android.intent.action.VIEW', data: url, package: pkg, flags: _newTask).launch();
        return true;
      } catch (_) {}
    }
    return false;
  }

  Future<String> play(String query, {int rank = 1, required ScreenAutomationService screen}) async {
    final q = query.trim();
    if (q.isEmpty) {
      final ok = await screen.clickFirstVideo(rank: rank);
      return ok
          ? 'Playing result $rank'
          : 'Could not find a video to play on the screen. Tell me what to search for.';
    }
    try {
      final hits = await _search(q);
      if (hits.length >= rank) {
        final v = hits[rank - 1];
        if (await _open('https://www.youtube.com/watch?v=${v.id}')) {
          return 'Playing ${v.title.isEmpty ? 'the top result for "$q"' : '"${v.title}"'} on YouTube';
        }
      }
    } catch (_) {}
    // Fallback: open the results page and tap the Nth video.
    if (await _open('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}')) {
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      for (var i = 0; i < 3; i++) {
        if (await screen.clickFirstVideo(rank: rank)) return 'Playing result $rank for "$q"';
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
    return 'Could not play a video for "$q".';
  }
}
