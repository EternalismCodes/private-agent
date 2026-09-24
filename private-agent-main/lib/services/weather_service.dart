import 'dart:convert';
import 'package:http/http.dart' as http;
import '../agent/safe_cast.dart';

/// Real weather for a named place via Open-Meteo (free, no API key).
class WeatherService {
  static const String _geoUrl = 'https://geocoding-api.open-meteo.com/v1/search';
  static const String _wxUrl = 'https://api.open-meteo.com/v1/forecast';
  static const Duration _timeout = Duration(seconds: 10);
  static const List<String> _dow = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const Map<int, String> _codes = {
    0: 'clear sky', 1: 'mostly clear', 2: 'partly cloudy', 3: 'overcast', 45: 'foggy', 48: 'freezing fog',
    51: 'light drizzle', 53: 'drizzle', 55: 'heavy drizzle', 56: 'freezing drizzle', 57: 'freezing drizzle',
    61: 'light rain', 63: 'rain', 65: 'heavy rain', 66: 'freezing rain', 67: 'freezing rain',
    71: 'light snow', 73: 'snow', 75: 'heavy snow', 77: 'snow grains', 80: 'light showers', 81: 'showers',
    82: 'violent showers', 85: 'snow showers', 86: 'heavy snow showers', 95: 'thunderstorm',
    96: 'thunderstorm with hail', 99: 'thunderstorm with hail',
  };

  Future<String> forecast(String location, {int days = 1, bool fahrenheit = false}) async {
    final query = location.trim();
    if (query.isEmpty) return 'Which city should I check the weather for?';
    final n = days < 1 ? 1 : (days > 7 ? 7 : days);
    try {
      final parts = query.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final hint = parts.skip(1).join(' ').toLowerCase();
      final g = await http
          .get(Uri.parse('$_geoUrl?name=${Uri.encodeQueryComponent(parts.first)}&count=10&language=en&format=json'))
          .timeout(_timeout);
      if (g.statusCode != 200) return 'Could not reach the weather service (${g.statusCode}).';
      final geo = jsonDecode(g.body);
      final results = geo is Map && geo['results'] is List ? geo['results'] as List : const [];
      if (results.isEmpty) return 'Could not find a place called "$query".';
      Map place = results.first as Map;
      if (hint.isNotEmpty) {
        for (final r in results) {
          if (r is! Map) continue;
          final hay = '${r['country']} ${r['admin1']} ${r['country_code']}'.toLowerCase();
          if (hint.split(' ').where((w) => w.length > 1).every((w) => hay.contains(w))) {
            place = r;
            break;
          }
        }
      }
      final lat = asDouble(place['latitude']);
      final lon = asDouble(place['longitude']);
      if (lat == null || lon == null) return 'Could not locate "$query".';

      final units = fahrenheit ? '&temperature_unit=fahrenheit&wind_speed_unit=mph' : '';
      final w = await http
          .get(Uri.parse('$_wxUrl?latitude=$lat&longitude=$lon'
              '&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m'
              '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max'
              '&forecast_days=$n&timezone=auto$units'))
          .timeout(_timeout);
      if (w.statusCode != 200) return 'Could not get the forecast (${w.statusCode}).';
      final j = jsonDecode(w.body) as Map;
      final cur = j['current'] is Map ? j['current'] as Map : null;
      final daily = j['daily'] is Map ? j['daily'] as Map : null;
      final tu = fahrenheit ? '°F' : '°C';
      final wu = fahrenheit ? 'mph' : 'km/h';
      String t(dynamic v) => asDouble(v)?.round().toString() ?? '?';
      final label = <String>{
        for (final e in [place['name'], place['admin1'], place['country']])
          if (e != null && '$e'.isNotEmpty) '$e',
      }.join(', ');

      final b = StringBuffer('Weather in $label: ');
      if (cur != null) {
        b.write('${t(cur['temperature_2m'])}$tu (feels ${t(cur['apparent_temperature'])}$tu), '
            '${_codes[asInt(cur['weather_code'])] ?? 'unknown conditions'}, '
            'humidity ${t(cur['relative_humidity_2m'])}%, wind ${t(cur['wind_speed_10m'])} $wu.');
      }
      if (daily != null) {
        final times = daily['time'] is List ? daily['time'] as List : const [];
        dynamic at(String k, int i) {
          final l = daily[k];
          return l is List && i < l.length ? l[i] : null;
        }
        for (var i = 0; i < times.length; i++) {
          final name = i == 0
              ? 'Today'
              : (i == 1 ? 'Tomorrow' : _dow[(DateTime.tryParse('${times[i]}')?.weekday ?? 1) - 1]);
          final rain = asInt(at('precipitation_probability_max', i));
          b.write(' $name: ${t(at('temperature_2m_min', i))}–${t(at('temperature_2m_max', i))}$tu, '
              '${_codes[asInt(at('weather_code', i))] ?? ''}${rain == null ? '' : ', $rain% rain'}.');
        }
      }
      return b.toString();
    } catch (e) {
      return 'Could not get the weather: check your internet connection.';
    }
  }
}
