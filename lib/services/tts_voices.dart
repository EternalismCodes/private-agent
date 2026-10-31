import 'package:flutter_tts/flutter_tts.dart';

/// One voice offered by the phone's text-to-speech engine.
class TtsVoice {
  final String name;
  final String locale;
  final int quality; // Android Voice quality: 500 very high … 100 very low
  final bool networkRequired;
  const TtsVoice(this.name, this.locale, this.quality, this.networkRequired);

  String get label {
    final q = quality >= 400 ? 'high quality' : (quality >= 300 ? 'normal' : 'basic');
    return '$name ($locale, $q${networkRequired ? ', online' : ''})';
  }
}

/// Finds and ranks the phone's installed voices for English and Hindi, so the
/// app can speak both naturally using the standard Android speech engine
/// (e.g. Google Speech Services) — nothing bundled, nothing extra to run.
class TtsVoiceCatalog {
  static final RegExp _devanagari = RegExp(r'[\u0900-\u097F]');

  /// True when most letters in [text] are Devanagari (Hindi).
  static bool looksHindi(String text) {
    var letters = 0;
    var hindi = 0;
    for (final r in text.runes) {
      final c = String.fromCharCode(r);
      if (_devanagari.hasMatch(c)) {
        hindi++;
        letters++;
      } else if (RegExp(r'\p{L}', unicode: true).hasMatch(c)) {
        letters++;
      }
    }
    return letters > 0 && hindi * 2 >= letters;
  }

  /// Installed voices for [lang] ('en' or 'hi'), best first.
  static Future<List<TtsVoice>> list(FlutterTts tts, String lang) async {
    final out = <TtsVoice>[];
    try {
      final dynamic raw = await tts.getVoices;
      if (raw is! List) return out;
      for (final v in raw) {
        if (v is! Map) continue;
        final name = (v['name'] ?? '').toString();
        final locale = (v['locale'] ?? '').toString();
        if (name.isEmpty || !locale.toLowerCase().replaceAll('_', '-').startsWith(lang)) continue;
        final features = (v['features'] ?? '').toString().toLowerCase();
        if (features.contains('notinstalled')) continue;
        final q = int.tryParse((v['quality'] ?? '').toString()) ?? 300;
        final net = v['network_required'] == true ||
            v['network_required']?.toString() == '1' ||
            v['network'] == true;
        out.add(TtsVoice(name, locale, q, net));
      }
    } catch (_) {}
    out.sort((a, b) => _score(b, lang).compareTo(_score(a, lang)));
    return out;
  }

  static int _score(TtsVoice v, String lang) {
    final n = v.name.toLowerCase();
    var s = v.quality;
    if (n.contains('neural') || n.contains('wavenet') || n.contains('studio') || n.contains('network')) s += 100;
    if (v.networkRequired) s += 50;
    final l = v.locale.toLowerCase().replaceAll('_', '-');
    if (lang == 'hi' && l == 'hi-in') s += 20;
    if (lang == 'en' && (l == 'en-in' || l == 'en-us')) s += 10;
    return s;
  }
}
