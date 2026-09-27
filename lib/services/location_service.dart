import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

/// A resolved fix: coordinates plus a human-readable label ("Bhatpara, West
/// Bengal, India") when reverse geocoding succeeded.
class DeviceLocation {
  final double lat;
  final double lon;
  final String label;
  const DeviceLocation(this.lat, this.lon, this.label);
}

/// Phrases that mean "wherever I currently am" rather than a named place.
final RegExp kHereLocationRe = RegExp(
  r'^\s*(here|near me|nearby|my location|current location|my current location|where i am)\s*[.!]?\s*$',
  caseSensitive: false,
);

/// Gets the phone's current position (best-effort, short timeout so it never
/// stalls a chat turn) and reverse-geocodes it into a readable label, so
/// "what's the weather" or "find the nearest cafe" work without the user
/// naming a place. Both the fix and the label are cached briefly — GPS is
/// slow and battery-costly, and the user's city doesn't change turn to turn.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  DeviceLocation? _cached;
  DateTime? _cachedAt;
  static const _cacheFor = Duration(minutes: 10);

  Future<bool> _ensurePermission() async {
    final status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) return false;
    return (await Permission.locationWhenInUse.request()).isGranted;
  }

  Future<String> _reverseGeocode(double lat, double lon) async {
    try {
      final r = await http.get(
        Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=12&addressdetails=1'),
        headers: const {
          // Nominatim's usage policy requires a real identifying User-Agent for unauthenticated use.
          'User-Agent': 'PrivateAgent-PersonalAutomationApp/1.0',
        },
      ).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return '';
      final j = jsonDecode(r.body);
      final addr = j is Map && j['address'] is Map ? j['address'] as Map : const {};
      final parts = <String>{
        for (final k in ['suburb', 'city', 'town', 'village', 'state', 'country'])
          if (addr[k] != null && '${addr[k]}'.isNotEmpty) '${addr[k]}',
      }.take(3).toList();
      return parts.join(', ');
    } catch (_) {
      return '';
    }
  }

  /// The current fix, from cache when recent enough. Returns null quickly
  /// (never throws, never hangs the turn) if location is off, permission was
  /// refused, or the phone can't get a fix in time.
  Future<DeviceLocation?> current({bool forceRefresh = false}) async {
    if (!forceRefresh && _cached != null && _cachedAt != null && DateTime.now().difference(_cachedAt!) < _cacheFor) {
      return _cached;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return _cached;
      if (!await _ensurePermission()) return _cached;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 8)),
      );
      final label = await _reverseGeocode(pos.latitude, pos.longitude);
      final loc = DeviceLocation(pos.latitude, pos.longitude, label);
      _cached = loc;
      _cachedAt = DateTime.now();
      return loc;
    } catch (_) {
      return _cached;
    }
  }

  /// Cache-only, instant: never triggers a GPS fix itself. Returns the last
  /// known fix if it's still fresh, otherwise kicks off a refresh in the
  /// background (for next time) and returns whatever's cached right now
  /// (possibly empty). This is what general prompt context uses on every
  /// turn — a chat message must never be made to wait ~10s for GPS just in
  /// case it turns out to be about a place.
  Future<String> peekContextLine() async {
    final fresh = _cached != null && _cachedAt != null && DateTime.now().difference(_cachedAt!) < _cacheFor;
    if (!fresh) {
      unawaited(current(forceRefresh: true));
    }
    return _lineFor(_cached);
  }

  /// One line for prompts: "Current location: Bhatpara, West Bengal, India
  /// (22.86, 88.37)." Empty string (never null) if location isn't available.
  /// This one *does* wait for a fix (bounded to the timeouts above) — use it
  /// only where location is actually needed (weather with no place named, a
  /// "nearest X" request), not on every turn.
  Future<String> contextLine() async => _lineFor(await current());

  String _lineFor(DeviceLocation? loc) {
    if (loc == null) return '';
    final where = loc.label.isEmpty ? '${loc.lat.toStringAsFixed(4)}, ${loc.lon.toStringAsFixed(4)}' : loc.label;
    return 'Current location: $where (${loc.lat.toStringAsFixed(4)}, ${loc.lon.toStringAsFixed(4)}). '
        'Use this for "near me" / "nearest" / weather-with-no-place requests — never ask the user where they are for these.';
  }
}
