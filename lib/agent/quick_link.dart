import 'package:flutter/foundation.dart';

/// Detects and builds direct links for plain search/lookup requests on
/// YouTube, Facebook, or Instagram via a fast LLM classification. This runs
/// async in parallel to the main automation flow: classification takes ~2
/// seconds (one model call), URL building is instant, so the link opens
/// around the same time the automation would start reading the screen —
/// but it *feels* responsive because the UI gets feedback immediately
/// (the "thinking" overlay, progress) rather than appearing stuck for 4-5
/// seconds with nothing on screen.
///
/// The LLM approach (rather than pure regex) is necessary because phrasing
/// varies a lot: "look up X on youtube", "find X on instagram", "search
/// facebook for X", "youtube X", etc., plus negatives like "don't send
/// anyone my search history on facebook". A classifier nails all of these
/// in one call and returns a structured result, whereas regex chains
/// explode in complexity and miss edge cases.
///
/// The result flows back into the agent's planning: if a link is found,
/// the planner can open it (faster) OR still prefer automation if the user
/// made it clear they want to interact further (e.g. "search youtube and
/// watch the first result" — the link just gets you to the results page,
/// but the actual "watch first result" step needs screen automation). The
/// LLM decides case-by-case.
class QuickLinkDetector {
  QuickLinkDetector._();

  /// Checks if the text looks like a search/lookup request (fire-and-forget
  /// heuristic, runs in ~10ms to skip the LLM call entirely if it's clearly
  /// NOT a search).
  static bool looksLikeSearch(String text) {
    final t = text.toLowerCase().trim();
    if (t.length > 500 || t.isEmpty) return false;
    final searchTerms = [
      'search', 'look up', 'find', 'what is', 'who is', 'lookup',
      'youtube', 'yt', 'instagram', 'insta', 'ig', 'facebook', 'fb',
    ];
    return searchTerms.any((term) => t.contains(term));
  }

  /// Builds the URL (or null) once [classification] is known. Instant.
  static String? buildUrl(
    String platform,
    String query, {
    bool isSearch = true,
    bool isProfile = false,
    bool isHashtag = false,
  }) {
    platform = platform.toLowerCase();
    if (query.trim().isEmpty) return null;

    // Canonicalize platform alias
    if (['yt', 'youtube'].contains(platform)) platform = 'youtube';
    if (['fb', 'facebook'].contains(platform)) platform = 'facebook';
    if (['insta', 'ig', 'instagram'].contains(platform)) platform = 'instagram';

    switch (platform) {
      case 'youtube':
        if (!isSearch) return null;
        return 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}';

      case 'instagram':
        if (isHashtag) {
          final tag = query.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
          if (tag.isEmpty) return null;
          return 'https://www.instagram.com/explore/tags/${Uri.encodeComponent(tag)}/';
        }
        if (isProfile) {
          final handle = query.replaceAll(RegExp(r'[^a-zA-Z0-9_.]'), '');
          if (handle.isEmpty) return null;
          return 'https://www.instagram.com/${Uri.encodeComponent(handle)}/';
        }
        if (isSearch) {
          return 'https://www.instagram.com/explore/search/keyword/?q=${Uri.encodeComponent(query)}';
        }
        return null;

      case 'facebook':
        if (!isSearch) return null;
        return 'https://www.facebook.com/search/top/?q=${Uri.encodeComponent(query)}';

      default:
        return null;
    }
  }
}

/// Result of an LLM classification attempt for a link.
class QuickLinkClassification {
  /// 'youtube', 'facebook', 'instagram', or empty if not a plain search
  final String platform;

  /// The query or lookup term (e.g. "cats", "rivaldo", "#photography")
  final String query;

  /// True if this is a search/results lookup
  final bool isSearch;

  /// True if the user is looking for a profile (Instagram only)
  final bool isProfile;

  /// True if the user is looking for a hashtag (Instagram only)
  final bool isHashtag;

  /// Confidence 0.0-1.0. If < 0.5, treat as a non-search intent.
  final double confidence;

  /// Non-empty if the request clearly requires further automation after the
  /// link (e.g. "search youtube and watch the first result" — the link gets
  /// you to results, but you still need to tap and watch).
  final String furtherGoal;

  QuickLinkClassification({
    this.platform = '',
    this.query = '',
    this.isSearch = false,
    this.isProfile = false,
    this.isHashtag = false,
    this.confidence = 0.0,
    this.furtherGoal = '',
  });

  bool get isValid => platform.isNotEmpty && query.isNotEmpty && confidence >= 0.5;

  String? buildUrl() => QuickLinkDetector.buildUrl(
    platform,
    query,
    isSearch: isSearch,
    isProfile: isProfile,
    isHashtag: isHashtag,
  );

  @override
  String toString() {
    if (!isValid) return 'QuickLinkClassification(invalid)';
    return 'QuickLinkClassification($platform/$query, conf=$confidence, url=${buildUrl()})';
  }
}
