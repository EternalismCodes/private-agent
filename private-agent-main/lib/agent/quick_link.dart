/// Builds a direct web/app link for a plain "search X on <platform>" request,
/// for the handful of platforms where the destination is fully determined by
/// the query text (YouTube, Facebook, Instagram). This lets the agent answer
/// in about a second — build the URL, open it — instead of the normal
/// screen-automation loop (open the app, read the screen, ask the model what
/// to tap, type, submit, read the screen again...), which is what "thinking"
/// costs several seconds for.
///
/// A link is only ever built for a *search/lookup* request. It is NOT built
/// (returns null, so the request falls through to the normal automation
/// path, which does "think like normal") whenever the request needs
/// anything past showing search results: sending a message, posting,
/// commenting, liking, following, DMing, uploading, replying, tagging,
/// calling, or buying/booking something. Those require clicking into a
/// specific result and interacting with it, which a static link can't do.
class QuickLink {
  QuickLink._();

  static final RegExp _interactiveVerbs = RegExp(
    r'\b(send|message|dm|post|comment|like|unlike|follow|unfollow|upload|'
    r'reply|share|call|tag|react|subscribe|save|download|buy|order|book|'
    r'login|log in|sign in|delete|remove|edit|update|create)\b',
    caseSensitive: false,
  );

  static const Map<String, List<String>> _platforms = {
    'youtube': ['youtube', 'yt'],
    'facebook': ['facebook', 'fb'],
    'instagram': ['instagram', 'insta', 'ig'],
  };

  // "search <query> on youtube" / "look up <query> on instagram" / "find <query> on facebook"
  static final RegExp _queryThenPlatform = RegExp(
    r'^\s*(?:please\s+)?(?:search(?:\s+for)?|look\s?up|find)\s+(.+?)\s+(?:on|in)\s+'
    r'(youtube|yt|facebook|fb|instagram|insta|ig)\s*[.!?]?\s*$',
    caseSensitive: false,
  );

  // "search youtube for <query>" / "youtube search <query>" / "search instagram <query>"
  static final RegExp _platformThenQuery = RegExp(
    r'^\s*(?:please\s+)?(?:search\s+)?(youtube|yt|facebook|fb|instagram|insta|ig)\s+'
    r'(?:search(?:\s+for)?|for)\s+(.+?)\s*[.!?]?\s*$',
    caseSensitive: false,
  );

  /// Returns the URL to open, or null if this isn't a plain search request
  /// for one of the three supported platforms.
  static String? build(String text) {
    final t = text.trim();
    if (t.isEmpty || _interactiveVerbs.hasMatch(t)) return null;

    String? platform;
    String? query;

    var m = _queryThenPlatform.firstMatch(t);
    if (m != null) {
      query = m.group(1);
      platform = m.group(2);
    } else {
      m = _platformThenQuery.firstMatch(t);
      if (m != null) {
        platform = m.group(1);
        query = m.group(2);
      }
    }

    if (platform == null || query == null) return null;
    query = query.trim();
    if (query.isEmpty) return null;

    switch (_canonicalPlatform(platform)) {
      case 'youtube':
        return 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}';

      case 'instagram':
        if (query.startsWith('#')) {
          final tag = query.substring(1).replaceAll(RegExp(r'\s+'), '');
          if (tag.isEmpty) return null;
          return 'https://www.instagram.com/explore/tags/${Uri.encodeComponent(tag)}/';
        }
        if (query.startsWith('@') && !query.contains(' ')) {
          final handle = query.substring(1);
          if (handle.isEmpty) return null;
          return 'https://www.instagram.com/${Uri.encodeComponent(handle)}/';
        }
        return 'https://www.instagram.com/explore/search/keyword/?q=${Uri.encodeComponent(query)}';

      case 'facebook':
        return 'https://www.facebook.com/search/top/?q=${Uri.encodeComponent(query)}';

      default:
        return null;
    }
  }

  static String? _canonicalPlatform(String raw) {
    final lower = raw.toLowerCase();
    for (final entry in _platforms.entries) {
      if (entry.value.contains(lower)) return entry.key;
    }
    return null;
  }
}
