/// Tolerant number parsing: models often send "7" or "5 minutes" where a
/// number is expected, which used to crash with
/// "type 'String' is not a subtype of type 'num?' in type cast".
int? asInt(dynamic v) {
  final d = asDouble(v);
  return d?.toInt();
}

double? asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final s = v.trim();
    final direct = double.tryParse(s);
    if (direct != null) return direct;
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(s);
    if (m != null) return double.tryParse(m.group(0)!);
  }
  return null;
}

/// Reads a clock time from {hour, minute} or {time: "7:30 pm"} (also
/// {hour: "07:30"}). Null when it can't be understood.
({int hour, int minute})? parseClock(Map<String, dynamic> p) {
  String raw = '';
  for (final e in [p['time'], p['hour']]) {
    final s = e?.toString().trim() ?? '';
    if (s.contains(':') || RegExp(r'[ap]\.?m', caseSensitive: false).hasMatch(s)) {
      raw = s;
      break;
    }
  }
  int? h;
  int? m;
  if (raw.isNotEmpty) {
    final mt = RegExp(r'(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?', caseSensitive: false).firstMatch(raw);
    if (mt != null) {
      h = int.parse(mt.group(1)!);
      m = int.tryParse(mt.group(2) ?? '') ?? 0;
      final ap = (mt.group(3) ?? '').toLowerCase();
      if (ap.startsWith('p') && h < 12) h += 12;
      if (ap.startsWith('a') && h == 12) h = 0;
    }
  } else {
    h = asInt(p['hour']);
    m = asInt(p['minute']) ?? 0;
  }
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return (hour: h, minute: m);
}

/// Reads a duration in seconds from {seconds}, {minutes}, {hours} or
/// {duration: "1h 30m" | "5 minutes" | 90}. Null when missing.
int? parseDurationSeconds(Map<String, dynamic> p) {
  double total = 0;
  var found = false;
  final unitRe = RegExp(r'(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b', caseSensitive: false);
  for (final key in ['duration', 'seconds', 'length', 'time']) {
    final v = p[key];
    if (v == null) continue;
    if (v is String) {
      var sum = 0.0;
      var any = false;
      for (final m in unitRe.allMatches(v)) {
        final n = double.parse(m.group(1)!);
        final u = m.group(2)!.toLowerCase();
        sum += u.startsWith('h') ? n * 3600 : (u.startsWith('m') ? n * 60 : n);
        any = true;
      }
      if (any) {
        total += sum;
        found = true;
        break;
      }
    }
    if (key == 'time') continue;
    final n = asDouble(v);
    if (n != null) {
      total += n;
      found = true;
      break;
    }
  }
  final mins = asDouble(p['minutes']);
  if (mins != null) {
    total += mins * 60;
    found = true;
  }
  final hrs = asDouble(p['hours']);
  if (hrs != null) {
    total += hrs * 3600;
    found = true;
  }
  if (!found) return null;
  final secs = total.round();
  return secs < 1 ? null : (secs > 86400 ? 86400 : secs);
}
