import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'contacts_service.dart';
import 'screen_automation_service.dart';

/// Sends a WhatsApp message the fast way: a wa.me deep link opens the chat with
/// the message already typed in (no searching contacts or the chat list
/// through the accessibility UI, which is what made it slow), then a single
/// tap sends it.
class WhatsappService {
  static const String _pkg = 'com.whatsapp';
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static final RegExp _phoneLike = RegExp(r'^\+?[\d\s().-]{6,}$');

  Future<String?> _resolveDigits(String contact, ContactsService contacts) async {
    final c = contact.trim();
    if (_phoneLike.hasMatch(c)) {
      final d = c.replaceAll(RegExp(r'[^\d+]'), '');
      return d.replaceFirst(RegExp(r'^\+'), '');
    }
    final phone = await contacts.getPhoneNumber(c);
    if (phone == null) return null;
    return phone.replaceAll(RegExp(r'[^\d+]'), '').replaceFirst(RegExp(r'^\+'), '');
  }

  Future<String> send(
    String contact,
    String message, {
    required ContactsService contacts,
    required ScreenAutomationService screen,
  }) async {
    final c = contact.trim();
    final m = message.trim();
    if (c.isEmpty) return 'Who should I message on WhatsApp?';
    if (m.isEmpty) return 'What should the message say?';

    final digits = await _resolveDigits(c, contacts);
    if (digits == null || digits.isEmpty) {
      return 'Could not find a phone number for "$c". Use the exact saved contact name or a phone number.';
    }

    try {
      await AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'https://wa.me/$digits?text=${Uri.encodeComponent(m)}',
        package: _pkg,
        flags: _newTask,
      ).launch();
    } catch (_) {
      try {
        await AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'https://wa.me/$digits?text=${Uri.encodeComponent(m)}',
          flags: _newTask,
        ).launch();
      } catch (e) {
        return 'Could not open WhatsApp: $e';
      }
    }

    for (var i = 0; i < 16; i++) {
      if (await screen.getCurrentPackage() == _pkg) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));

    for (var attempt = 0; attempt < 5; attempt++) {
      if (await screen.clickByText('Send')) {
        return 'Sent to $c on WhatsApp: "$m"';
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return 'Opened the chat with $c and typed the message, but could not tap Send — the app may still be loading. Try again, or send it yourself this once.';
  }
}
