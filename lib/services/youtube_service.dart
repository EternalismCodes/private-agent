import 'dart:async';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:http/http.dart' as http;
import 'screen_automation_service.dart';
import 'favorites_service.dart';

/// "Play the top result": looks up the real video id from YouTube's search
/// page and opens it straight in the YouTube app (no tapping needed). If that
/// fails it falls back to tapping the Nth result through accessibility.
class YoutubeService {
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static final RegExp _card = RegExp(r'"videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})"');
  static final RegExp _any = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"');
  static final RegExp _title = RegExp(r'"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"');
  static final RegExp _channel =
      RegExp(r'"(?:shortBylineText|longBylineText|ownerText)":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"');

  Future<List<({String id, String title, String channel})>> _search(String q) async {
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
    final out = <({String id, String title, String channel})>[];
    String clean(String s) => s.replaceAll(r'\u0026', '&').replaceAll(r'\"', '"');
    for (final m in matches) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      final end = m.end + 900 > body.length ? body.length : m.end + 900;
      final window = body.substring(m.end, end);
      final t = _title.firstMatch(window)?.group(1) ?? '';
      final ch = _channel.firstMatch(window)?.group(1) ?? '';
      out.add((id: id, title: clean(t), channel: clean(ch)));
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

  Future<String> play(
    String query, {
    int rank = 1,
    required ScreenAutomationService screen,
    FavoritesService? favorites,
  }) async {
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
          if (favorites != null) unawaited(favorites.recordPlay(v.channel, v.id, v.title));
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

  /// "Play something I like": picks up on a channel that has come up in 2+
  /// separate plays and starts something from it.
  Future<String> playFavorite({required FavoritesService favorites, required ScreenAutomationService screen}) async {
    final fav = await favorites.top();
    if (fav == null) {
      return "I don't have a favorite of yours yet — play a couple of things and I'll start noticing patterns.";
    }
    final result = await play(fav.channel, screen: screen, favorites: favorites);
    return result.startsWith('Playing') ? '$result (from ${fav.channel}, one of your favorites)' : result;
  }
}
