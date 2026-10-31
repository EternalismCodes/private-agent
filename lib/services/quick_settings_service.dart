import 'package:android_intent_plus/android_intent.dart';
import 'shizuku_service.dart';

/// Result of [QuickSettingsService.apply].
class QuickSettingResult {
  final String message;
  final bool done; // true = changed directly; false = a Settings page was opened
  final String label;
  const QuickSettingResult(this.message, {required this.done, required this.label});
}

/// Wi-Fi, Bluetooth, airplane mode and other everyday switches.
///
/// Android no longer lets normal apps flip most of these, so: with Shizuku it
/// changes them directly; otherwise it opens the exact Settings page (or the
/// quick panel) so the on-screen automation can finish the toggle.
class QuickSettingsService {
  final ShizukuService _shizuku;
  QuickSettingsService(this._shizuku);

  static const _aliases = <String, List<String>>{
    'wifi': ['wifi', 'wi-fi', 'wi fi', 'wlan', 'internet'],
    'bluetooth': ['bluetooth', 'bt'],
    'airplane': ['airplane', 'aeroplane', 'flight mode', 'flight', 'airplane mode'],
    'data': ['mobile data', 'cellular', 'data', 'mobile network'],
    'location': ['location', 'gps'],
    'nfc': ['nfc'],
    'hotspot': ['hotspot', 'tethering', 'portable hotspot'],
    'dnd': ['do not disturb', 'dnd', 'silent mode', 'focus'],
    'battery_saver': ['battery saver', 'power saving', 'low power'],
    'auto_rotate': ['auto rotate', 'auto-rotate', 'rotation', 'screen rotation'],
    'display': ['display', 'screen', 'dark mode', 'dark theme', 'theme'],
    'sound': ['sound', 'volume', 'ringtone'],
    'battery': ['battery'],
    'accessibility': ['accessibility'],
    'apps': ['apps', 'applications', 'app settings'],
    'storage': ['storage'],
    'security': ['security', 'lock screen', 'fingerprint'],
    'language': ['language', 'languages'],
    'date': ['date', 'time', 'date and time'],
    'voice': ['text to speech', 'tts', 'voice output'],
    'settings': ['settings'],
  };

  static const _labels = <String, String>{
    'wifi': 'Wi-Fi',
    'bluetooth': 'Bluetooth',
    'airplane': 'Airplane mode',
    'data': 'Mobile data',
    'location': 'Location',
    'nfc': 'NFC',
    'hotspot': 'Hotspot',
    'dnd': 'Do Not Disturb',
    'battery_saver': 'Battery Saver',
    'auto_rotate': 'Auto-rotate',
  };

  static String? normalize(String raw) {
    final t = raw.toLowerCase().trim();
    if (t.isEmpty) return null;
    for (final e in _aliases.entries) {
      if (e.value.any((a) => t == a)) return e.key;
    }
    for (final e in _aliases.entries) {
      if (e.value.any((a) => t.contains(a))) return e.key;
    }
    return null;
  }

  static const _shell = <String, List<String>>{
    // key: [command when on, command when off]
    'wifi': ['svc wifi enable', 'svc wifi disable'],
    'bluetooth': ['cmd bluetooth_manager enable', 'cmd bluetooth_manager disable'],
    'data': ['svc data enable', 'svc data disable'],
    'airplane': ['cmd connectivity airplane-mode enable', 'cmd connectivity airplane-mode disable'],
    'nfc': ['svc nfc enable', 'svc nfc disable'],
    'location': ['settings put secure location_mode 3', 'settings put secure location_mode 0'],
    'dnd': ['cmd notification set_dnd priority', 'cmd notification set_dnd off'],
    'battery_saver': ['settings put global low_power 1', 'settings put global low_power 0'],
    'auto_rotate': ['settings put system accelerometer_rotation 1', 'settings put system accelerometer_rotation 0'],
  };

  static const _pages = <String, String>{
    'wifi': 'android.settings.panel.action.WIFI',
    'bluetooth': 'android.settings.BLUETOOTH_SETTINGS',
    'airplane': 'android.settings.AIRPLANE_MODE_SETTINGS',
    'data': 'android.settings.NETWORK_OPERATOR_SETTINGS',
    'location': 'android.settings.LOCATION_SOURCE_SETTINGS',
    'nfc': 'android.settings.NFC_SETTINGS',
    'hotspot': 'android.settings.WIRELESS_SETTINGS',
    'dnd': 'android.settings.ZEN_MODE_PRIORITY_SETTINGS',
    'battery_saver': 'android.settings.BATTERY_SAVER_SETTINGS',
    'auto_rotate': 'android.settings.DISPLAY_SETTINGS',
    'display': 'android.settings.DISPLAY_SETTINGS',
    'sound': 'android.settings.SOUND_SETTINGS',
    'battery': 'android.settings.BATTERY_SAVER_SETTINGS',
    'accessibility': 'android.settings.ACCESSIBILITY_SETTINGS',
    'apps': 'android.settings.APPLICATION_SETTINGS',
    'storage': 'android.settings.INTERNAL_STORAGE_SETTINGS',
    'security': 'android.settings.SECURITY_SETTINGS',
    'language': 'android.settings.LOCALE_SETTINGS',
    'date': 'android.settings.DATE_SETTINGS',
    'voice': 'com.android.settings.TTS_SETTINGS',
    'settings': 'android.settings.SETTINGS',
  };

  /// [state]: 'on', 'off' or 'open' (just show the page).
  Future<QuickSettingResult?> apply(String settingName, String state) async {
    final key = normalize(settingName);
    if (key == null) return null;
    final label = _labels[key] ?? key.replaceAll('_', ' ');
    final wantOn = state == 'on';
    final wantOff = state == 'off';

    if ((wantOn || wantOff) && _shell.containsKey(key)) {
      await _shizuku.checkAvailability();
      if (_shizuku.isAvailable && (_shizuku.hasPermission || await _shizuku.requestPermission())) {
        final out = await _shizuku.runCommand(_shell[key]![wantOn ? 0 : 1]);
        if (!out.toLowerCase().startsWith('error') && !out.toLowerCase().contains('denied')) {
          return QuickSettingResult('$label turned ${wantOn ? 'on' : 'off'}.', done: true, label: label);
        }
      }
    }

    final action = _pages[key];
    if (action == null) return null;
    try {
      await AndroidIntent(action: action).launch();
    } catch (_) {
      try {
        await const AndroidIntent(action: 'android.settings.SETTINGS').launch();
      } catch (e) {
        return QuickSettingResult('Could not open $label settings: $e', done: true, label: label);
      }
    }
    return QuickSettingResult('Opened $label settings.', done: !(wantOn || wantOff), label: label);
  }
}
