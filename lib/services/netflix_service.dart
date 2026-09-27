import 'dart:async';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'ai_service.dart';
import 'app_launcher_service.dart';
import 'favorites_service.dart';
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'task_executor.dart';

/// "Play <show> on Netflix": Netflix has no public, unauthenticated search
/// API the way YouTube's results page can be scraped, so unlike
/// [YoutubeService] this can't resolve a title to a specific link by itself.
/// Instead it opens Netflix's own in-app search for the title (a real,
/// documented `nflx://` deep link) to save the searching/typing, then hands
/// the rest ("open the top result and press play") to the existing
/// screen-reading agent — which copes with Netflix's row-based, frequently
/// reshuffled layout far better than a coordinate guess would.
class NetflixService {
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static const String _package = 'com.netflix.mediaclient';

  Future<bool> _openSearch(String query) async {
    final q = Uri.encodeComponent(query);
    for (final uri in [
      'nflx://www.netflix.com/search?q=$q',
      'https://www.netflix.com/search?q=$q',
    ]) {
      try {
        await AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: uri,
          package: _package,
          flags: _newTask,
        ).launch();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Plays [title] on Netflix. Records it as a favorites candidate on
  /// success so a repeated title can later be recognised as "your favorite".
  Future<String> play(
    String title, {
    required ScreenAutomationService screen,
    required AppLauncherService appLauncher,
    required ShizukuService shizuku,
    AiService? aiService,
    FavoritesService? favorites,
    void Function(String)? onProgress,
  }) async {
    final t = title.trim();
    if (t.isEmpty) return 'What should I play on Netflix?';
    if (aiService == null) {
      return 'Could not play "$t" on Netflix: no AI provider is set up to navigate the app (add one in Settings).';
    }

    onProgress?.call('Opening Netflix and searching for "$t"…');
    final opened = await _openSearch(t);
    if (opened) await Future<void>.delayed(const Duration(milliseconds: 2800));

    final executor = TaskExecutor(
      aiService: aiService,
      screenService: screen,
      appLauncher: appLauncher,
      shizukuService: shizuku,
      onProgress: onProgress,
      fastSettle: true,
    );
    final goal = opened
        ? 'Netflix is already open with search results for "$t". Open the top matching result (the exact title, or the closest match) and press Play — choose "Resume" if it offers to resume something already in progress.'
        : 'Open Netflix, search for "$t", open the top matching result and press Play (choose "Resume" if offered).';

    final result = await executor.executeTask(goal);
    if (executor.lastOutcome == TaskOutcome.success) {
      if (favorites != null) unawaited(favorites.recordPlay(t, '', t));
      return 'Playing "$t" on Netflix.';
    }
    return result;
  }

  /// "Play something I like on Netflix": picks up on a show that has come up
  /// in 2+ separate plays and starts it again.
  Future<String> playFavorite({
    required FavoritesService favorites,
    required ScreenAutomationService screen,
    required AppLauncherService appLauncher,
    required ShizukuService shizuku,
    AiService? aiService,
    void Function(String)? onProgress,
  }) async {
    final fav = await favorites.top();
    if (fav == null) {
      return "I don't have a favorite Netflix show of yours yet — ask me to play a couple of things on Netflix by name and I'll start noticing what you go back to.";
    }
    final result = await play(
      fav.channel,
      screen: screen,
      appLauncher: appLauncher,
      shizuku: shizuku,
      aiService: aiService,
      favorites: favorites,
      onProgress: onProgress,
    );
    return result.startsWith('Playing') ? '$result (one of your favorites)' : result;
  }
}
