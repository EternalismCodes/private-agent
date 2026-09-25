import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'contacts_service.dart';
import 'screen_automation_service.dart';

/// Marks a result that the fast path couldn't finish, so the caller can fall
/// back to full UI automation transparently, in the same turn.
const String kWhatsappFallbackPrefix = 'FALLBACK:';

/// Sends a WhatsApp message the fast way: a wa.me deep link opens the chat with
/// the message already typed in (no searching contacts or the chat list
/// through the accessibility UI, which is what made it slow), then a single
/// tap sends it. Contact-name resolution or an unusual number format can
/// still fail the fast path — when that happens this returns a
/// [kWhatsappFallbackPrefix]-prefixed result instead of a hard error, so the
/// caller can drop back to slow-but-reliable UI automation in the same turn
/// rather than the model discovering the failure and retrying a step later
/// (which is what made it feel like it always took the slow path anyway).
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

  Future<String?> _open(String digits, String message) async {
    final url = 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
    for (final pkg in [..._packages, null]) {
      try {
        await AndroidIntent(action: 'android.intent.action.VIEW', data: url, package: pkg, flags: _newTask).launch();
        return pkg;
      } catch (_) {}
    }
    return null;
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
      return '$kWhatsappFallbackPrefix could not find a saved number for "$c" (checked contacts by exact and partial name match).';
    }
    // A number with no country code (short, local-format) is the classic
    // reason wa.me silently rejects an otherwise-real contact; still try it
    // (many stored numbers do include the code), but don't be surprised if
    // the fallback below ends up doing the real work.
    final opened = await _open(digits, m);
    if (opened == null) {
      return '$kWhatsappFallbackPrefix could not open WhatsApp (not installed, or the intent was blocked).';
    }

    for (var i = 0; i < 16; i++) {
      final pkg = await screen.getCurrentPackage();
      if (pkg == 'com.whatsapp' || pkg == 'com.whatsapp.w4b') break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
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
