import '../models/agent_action.dart';
import '../models/chat_message.dart';
import '../services/action_handler.dart';
import '../services/ai_service.dart';

/// Opens an app and makes sure it really opened.
///
/// Android silently blocks `startActivity` from an app that is in the
/// background (which is exactly the situation of a scheduled task). When the
/// normal launch had no effect, this falls back to driving the launcher
/// through the accessibility service: Home, then tap the app's icon by name.
class AppOpener {
  AppOpener._();

  static const String _self = 'com.orailnoor.privateagent';

  static final RegExp _failedText = RegExp(
    r'^(error|could not|cannot|can.t|no app|not found|failed|unable)',
    caseSensitive: false,
  );

  static Future<AgentActionResult> open(
    ActionHandler actions,
    AiService ai,
    String name, {
    void Function(String message)? onProgress,
  }) async {
    final screen = actions.screenAutomation;
    final before = await screen.getCurrentPackage() ?? '';

    final result = await actions.execute(
      AgentAction(action: 'open_app', params: {'app_name': name}, response: ''),
      aiService: ai,
      onProgress: onProgress,
    );
    final details = (result.details ?? '').trim();
    if (!result.success || _failedText.hasMatch(details)) return result;

    // Did the foreground app actually change?
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final now = await screen.getCurrentPackage() ?? '';
      if (now.isNotEmpty && now != before) return result;
    }
    if (before.isNotEmpty && before != _self && before.toLowerCase().contains(name.toLowerCase())) {
      return result; // it was already the app in front
    }

    // The launch was blocked: use the launcher instead.
    onProgress?.call('Opening $name from the home screen…');
    await screen.pressHome();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final tapped = await screen.clickByText(name);
    if (tapped) {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final now = await screen.getCurrentPackage() ?? '';
        if (now.isNotEmpty && now != before) {
          return AgentActionResult(actionType: 'open_app', success: true, details: 'Opened $name');
        }
      }
    }
    return AgentActionResult(
      actionType: 'open_app',
      success: false,
      details:
          'Could not open $name: Android blocked the launch from the background. Keep PrivateAgent open, or allow "Display over other apps" for it.',
    );
  }
}
