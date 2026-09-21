import 'dart:convert';

/// Helpers for dealing with messy LLM output.
class JsonUtils {
  JsonUtils._();

  /// Removes `<think>`, `<thinking>` and `<reasoning>` blocks (closed or not).
  static String stripThinking(String text) {
    var out = text.replaceAll(
      RegExp(r'<(think|thinking|reasoning)>[\s\S]*?</\1>', caseSensitive: false),
      '',
    );
    final open = RegExp(
      r'<(think|thinking|reasoning)>',
      caseSensitive: false,
    ).firstMatch(out);
    if (open != null) out = out.substring(0, open.start);
    final orphan = RegExp(
      r'</(think|thinking|reasoning)>',
      caseSensitive: false,
    ).firstMatch(out);
    if (orphan != null) out = out.substring(orphan.end);
    return out.trim();
  }

  /// Finds the first JSON object inside [text] (code fences and chatter are
  /// ignored) and decodes it. Truncated objects are repaired when possible.
  static Map<String, dynamic>? extractObject(String text) {
    final slice = _balancedSlice(text, '{');
    if (slice == null) return null;
    try {
      final decoded = jsonDecode(slice);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static List<dynamic>? extractArray(String text) {
    final slice = _balancedSlice(text, '[');
    if (slice == null) return null;
    try {
      final decoded = jsonDecode(slice);
      if (decoded is List) return decoded;
    } catch (_) {}
    return null;
  }

  static String? _balancedSlice(String text, String open) {
    final start = text.indexOf(open);
    if (start < 0) return null;
    final stack = <String>[];
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        stack.add('}');
      } else if (ch == '[') {
        stack.add(']');
      } else if (ch == '}' || ch == ']') {
        if (stack.isEmpty) return null;
        stack.removeLast();
        if (stack.isEmpty) return text.substring(start, i + 1);
      }
    }

    // The text ended before the object closed: try to repair it.
    var repaired = text.substring(start).trimRight();
    if (inString) repaired = '$repaired"';
    if (repaired.endsWith(',')) {
      repaired = repaired.substring(0, repaired.length - 1);
    }
    for (final closer in stack.reversed) {
      repaired += closer;
    }
    return repaired;
  }

  /// Best-effort conversion of a dynamic value to a trimmed string.
  static String str(dynamic value, [String fallback = '']) {
    if (value == null) return fallback;
    final s = value.toString().trim();
    return s.isEmpty ? fallback : s;
  }

  static bool boolOf(dynamic value, [bool fallback = false]) {
    if (value is bool) return value;
    if (value is String) {
      final v = value.toLowerCase().trim();
      if (v == 'true' || v == 'yes') return true;
      if (v == 'false' || v == 'no') return false;
    }
    return fallback;
  }

  /// Turns markdown into something that sounds fine when read aloud.
  static String forSpeech(String markdown, {int maxChars = 500}) {
    var t = markdown.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
    t = t.replaceAllMapped(
      RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    t = t
        .replaceAll(RegExp(r'[*_#>~|]+'), ' ')
        .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.length > maxChars) {
      final cut = t.substring(0, maxChars);
      final lastStop = cut.lastIndexOf(RegExp(r'[.!?]'));
      t = lastStop > maxChars ~/ 2 ? cut.substring(0, lastStop + 1) : cut;
    }
    return t;
  }
}

/// Result of splitting a model response into reasoning and answer.
class ThinkSplit {
  final String reasoning;
  final String answer;

  /// True while a reasoning block has been opened but not yet closed
  /// (i.e. the model is still "thinking" in a streamed response).
  final bool thinkingOpen;

  const ThinkSplit(this.reasoning, this.answer, this.thinkingOpen);
}

class ThinkParser {
  ThinkParser._();

  static ThinkSplit split(String raw) {
    final parts = <String>[];
    var rest = raw.replaceAllMapped(
      RegExp(r'<(think|thinking|reasoning)>([\s\S]*?)</\1>', caseSensitive: false),
      (m) {
        parts.add((m.group(2) ?? '').trim());
        return '';
      },
    );

    final orphan = RegExp(
      r'</(think|thinking|reasoning)>',
      caseSensitive: false,
    ).firstMatch(rest);
    if (orphan != null) {
      parts.add(rest.substring(0, orphan.start).trim());
      rest = rest.substring(orphan.end);
    }

    var open = false;
    final openMatch = RegExp(
      r'<(think|thinking|reasoning)>',
      caseSensitive: false,
    ).firstMatch(rest);
    if (openMatch != null) {
      parts.add(rest.substring(openMatch.end).trim());
      rest = rest.substring(0, openMatch.start);
      open = true;
    }

    rest = rest.replaceAll(RegExp(r'</?answer>', caseSensitive: false), '').trim();
    parts.removeWhere((p) => p.isEmpty);
    return ThinkSplit(parts.join('\n\n'), rest, open);
  }
}
