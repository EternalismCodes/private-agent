import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'contacts_service.dart';
import 'screen_automation_service.dart';

/// Marks a result that the fast path couldn't finish, so the caller can fall
/// back to full UI automation transparently, in the same turn.
const String kWhatsappFallbackPrefix = 'FALLBACK:';

/// Sends a WhatsApp message the fast way. Two fast paths, tried in order:
///
///  1. Jump straight to the chat via WhatsApp's own entry in Android's
///     Contacts Provider (present for anyone WhatsApp has synced) — no
///     phone number needed at all, so a contact saved with a local-format
///     number (no country code), spaces, or any other formatting quirk
///     still works, since we never have to parse their number ourselves.
///  2. A wa.me deep link with the number pulled from Contacts, for people
///     who aren't showing up in WhatsApp's own contact data yet.
///
/// Either way, only "type the message and tap Send" is left for the
/// accessibility service to do — the slow part (searching contacts, opening
/// the chat list, finding the right person) never has to happen.
class WhatsappService {
  static const List<String> _packages = ['com.whatsapp', 'com.whatsapp.w4b'];
  static const List<int> _newTask = <int>[Flag.FLAG_ACTIVITY_NEW_TASK];
  static final RegExp _phoneLike = RegExp(r'^\+?[\d\s().-]{6,}$');

  Future<String?> _resolveDigits(String contact, ContactsService contacts) async {
    final c = contact.trim();
    if (_phoneLike.hasMatch(c)) {
      final d = c.replaceAll(RegExp(r'[^\d+]'), '');
      return d.replaceFirst(RegExp(r'^\+'), '');
    }
    // Prefer an exact name match over ContactsService's default "contains"
    // search, which can grab the wrong person when several names overlap.
    final matches = await contacts.searchContacts(c);
    if (matches.isEmpty) return null;
    final exact = matches.where((m) => m.displayName.trim().toLowerCase() == c.toLowerCase());
    final pick = exact.isNotEmpty ? exact.first : matches.first;
    if (pick.phones.isEmpty) return null;
    final raw = pick.phones.first.number;
    return raw.replaceAll(RegExp(r'[^\d+]'), '').replaceFirst(RegExp(r'^\+'), '');
  }

  Future<String?> _openUri(String uri) async {
    for (final pkg in [..._packages, null]) {
      try {
        await AndroidIntent(action: 'android.intent.action.VIEW', data: uri, package: pkg, flags: _newTask).launch();
        return pkg;
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _open(String digits, String message) =>
      _openUri('https://wa.me/$digits?text=${Uri.encodeComponent(message)}');

  Future<bool> _waitForWhatsapp(ScreenAutomationService screen) async {
    for (var i = 0; i < 16; i++) {
      final pkg = await screen.getCurrentPackage();
      if (pkg == 'com.whatsapp' || pkg == 'com.whatsapp.w4b') return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  Future<bool> _typeAndSend(ScreenAutomationService screen, String message) async {
    var typed = false;
    for (var attempt = 0; attempt < 4 && !typed; attempt++) {
      typed = await screen.typeText(message, fieldHint: 'Message');
      if (!typed) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!typed) return false;
    for (var attempt = 0; attempt < 6; attempt++) {
      if (await screen.clickByText('Send')) return true;
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return false;
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

    // Fast path 1: jump to the chat via WhatsApp's own contact link, then
    // type the message ourselves — skips phone-number resolution entirely.
    if (!_phoneLike.hasMatch(c)) {
      final chatUri = await screen.resolveWhatsappChatUri(c);
      if (chatUri != null) {
        final opened = await _openUri(chatUri);
        if (opened != null && await _waitForWhatsapp(screen)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          if (await _typeAndSend(screen, m)) {
            return 'Sent to $c on WhatsApp: "$m"';
          }
        }
      }
    }

    // Fast path 2: a wa.me link with a number pulled from Contacts.
    final digits = await _resolveDigits(c, contacts);
    if (digits == null || digits.isEmpty) {
      return '$kWhatsappFallbackPrefix could not find "$c" in WhatsApp\'s own contacts, and no saved phone number either.';
    }
    // A number with no country code (short, local-format) is the classic
    // reason wa.me silently rejects an otherwise-real contact; still try it
    // (many stored numbers do include the code), but don't be surprised if
    // the fallback below ends up doing the real work.
    final opened = await _open(digits, m);
    if (opened == null) {
      return '$kWhatsappFallbackPrefix could not open WhatsApp (not installed, or the intent was blocked).';
    }
    if (!await _waitForWhatsapp(screen)) {
      return '$kWhatsappFallbackPrefix WhatsApp never came to the foreground.';
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));

    for (var attempt = 0; attempt < 6; attempt++) {
      if (await screen.clickByText('Send')) {
        return 'Sent to $c on WhatsApp: "$m"';
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return '$kWhatsappFallbackPrefix opened the chat for "$c" but never found a Send button — the number is likely missing its country code or the chat did not load.';
  }
}
