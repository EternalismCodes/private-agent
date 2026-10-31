import 'ai_service.dart';
import 'app_launcher_service.dart';
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'task_executor.dart';

/// Hands work PrivateAgent is not good at to a stronger assistant app on the
/// phone: Gemini for images, Claude for websites, apps and other big builds.
/// If Claude's usage limit is hit it falls back to Gemini. Small jobs
/// (rewording a message, short answers) never come here.
class AiDelegateService {
  static const _apps = <String, _Target>{
    'gemini': _Target('Gemini', 'com.google.android.apps.bard', 'https://gemini.google.com/app'),
    'claude': _Target('Claude', 'com.anthropic.claude', 'https://claude.ai/new'),
  };

  /// Messages these apps show when the free/plan limit has been used up.
  static final RegExp _limit = RegExp(
    r"(usage limit|limit reached|reached (your|the) [a-z ]*limit|out of (free )?messages|"
    r"come back (at|after|in|later)|upgrade to continue|try again (in|later|after)|too many (messages|requests)|"
    r"limit will reset|messages? (limit|remaining))",
    caseSensitive: false,
  );

  Future<String> send({
    required String target,
    required String prompt,
    required AiService ai,
    required ScreenAutomationService screen,
    required AppLauncherService launcher,
    required ShizukuService shizuku,
    void Function(String)? onProgress,
    bool fellBack = false,
  }) async {
    final key = target.toLowerCase().contains('gemini') ? 'gemini' : 'claude';
    final app = _apps[key]!;
    onProgress?.call('Opening ${app.name}…');

    await launcher.openPackage(app.package);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if ((await screen.getCurrentPackage()) != app.package) {
      // Not installed (or it did not open): use the website instead.
      await launcher.openUrl(app.web);
      await Future<void>.delayed(const Duration(milliseconds: 3000));
    }

    // Claude may already be out of messages before we even type.
    if (key == 'claude' && !fellBack && _limit.hasMatch(await screen.getScreenDescription())) {
      onProgress?.call('Claude is at its limit — switching to Gemini…');
      return send(target: 'gemini', prompt: prompt, ai: ai, screen: screen, launcher: launcher, shizuku: shizuku, onProgress: onProgress, fellBack: true);
    }

    onProgress?.call('Sending the request to ${app.name}…');
    final executor = TaskExecutor(
      aiService: ai,
      screenService: screen,
      appLauncher: launcher,
      shizukuService: shizuku,
      onProgress: onProgress,
    );
    final result = await executor.executeTask(
      'In ${app.name} (already open), start a NEW chat if one is not already empty, tap the message box, '
      'type EXACTLY the text below as the message, and send it. Then stop; do not wait for the answer.\n\nMESSAGE:\n$prompt',
    );

    await Future<void>.delayed(const Duration(seconds: 5));
    if (key == 'claude' && !fellBack && _limit.hasMatch(await screen.getScreenDescription())) {
      onProgress?.call('Claude is at its limit — switching to Gemini…');
      return send(target: 'gemini', prompt: prompt, ai: ai, screen: screen, launcher: launcher, shizuku: shizuku, onProgress: onProgress, fellBack: true);
    }

    final failed = RegExp(r'^(error|could not|cannot|unable)', caseSensitive: false).hasMatch(result.trim());
    if (failed) return 'Could not send the request to ${app.name}: $result';
    final note = fellBack ? 'Claude was at its limit, so I used Gemini instead. ' : '';
    return '${note}Sent your request to ${app.name}. The answer is on screen there.';
  }
}

class _Target {
  final String name;
  final String package;
  final String web;
  const _Target(this.name, this.package, this.web);
}
