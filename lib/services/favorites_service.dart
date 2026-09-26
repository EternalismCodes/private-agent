import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A thing that has come up repeatedly for one domain (a YouTube channel, a
/// Netflix show, ...). The field names are historical (from the original
/// YouTube-only version) but the class is generic: [channel] just holds the
/// item's name/title.
class FavoriteChannel {
  final String channel;
  int count;
  String lastVideoId;
  String lastTitle;
  FavoriteChannel(this.channel, this.count, this.lastVideoId, this.lastTitle);

  Map<String, dynamic> toJson() => {'channel': channel, 'count': count, 'lastVideoId': lastVideoId, 'lastTitle': lastTitle};
  factory FavoriteChannel.fromJson(Map<String, dynamic> j) =>
      FavoriteChannel('${j['channel']}', (j['count'] as num?)?.toInt() ?? 0, '${j['lastVideoId'] ?? ''}', '${j['lastTitle'] ?? ''}');
}

/// Notices when the same item (a YouTube channel, a Netflix show, ...) comes
/// up across separate play requests for a given [domain], so "play something
/// I like" has something real to go on — nothing is asked for up front, it's
/// just noticed from what actually gets played.
///
/// Each domain keeps its own separate list (a YouTube favorite never bleeds
/// into "play my favorite on Netflix" and vice versa).
class FavoritesService {
  /// 'youtube', 'netflix', etc. Kept for backward compatibility: the
  /// original YouTube-only storage key is preserved exactly when [domain]
  /// is 'youtube', so nobody's existing favorites are lost.
  final String domain;
  const FavoritesService({this.domain = 'youtube'});

  String get _key => domain == 'youtube' ? 'yt_favorite_channels_v1' : 'favorite_items_v1_$domain';
  static const int _favoriteThreshold = 2;

  Future<List<FavoriteChannel>> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).map((e) => FavoriteChannel.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<FavoriteChannel> list) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(list.map((c) => c.toJson()).toList()));
    } catch (_) {}
  }

  /// Call after every real, named-query play. No-op for an unknown item.
  Future<void> recordPlay(String item, String videoId, String title) async {
    final c = item.trim();
    if (c.isEmpty) return;
    final list = await _load();
    final existing = list.where((f) => f.channel.toLowerCase() == c.toLowerCase());
    if (existing.isNotEmpty) {
      final f = existing.first;
      f.count++;
      f.lastVideoId = videoId;
      f.lastTitle = title;
    } else {
      list.add(FavoriteChannel(c, 1, videoId, title));
    }
    list.sort((a, b) => b.count.compareTo(a.count));
    await _save(list.take(30).toList());
  }

  /// The item that has come up in 2+ separate plays, if any (highest count first).
  Future<FavoriteChannel?> top() async {
    final list = await _load();
    final favorites = list.where((f) => f.count >= _favoriteThreshold).toList();
    return favorites.isEmpty ? null : favorites.first;
  }

  Future<List<FavoriteChannel>> all() => _load();
}
