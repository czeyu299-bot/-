import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

class WeatherService {
  static Map<String, dynamic> _cache = {};
  static DateTime? _cacheTime;

  static void clearCache() {
    _cache = {};
    _cacheTime = null;
  }

  static Future<Map<String, dynamic>> fetchDaily({int days = 10}) async {
    if (_cacheTime != null &&
        DateTime.now().difference(_cacheTime!).inMinutes < 10) {
      return _cache;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return {};
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.low),
    );

    final url = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${pos.latitude}&longitude=${pos.longitude}'
      '&daily=weather_code,temperature_2m_max,temperature_2m_min'
      '&timezone=auto&forecast_days=$days',
    );

    final resp = await http.get(url);
    if (resp.statusCode != 200) return {};

    final data = jsonDecode(resp.body)['daily'];
    final times = List<String>.from(data['time']);
    final codes = List<int>.from(data['weather_code']);
    final maxT = List<double>.from(data['temperature_2m_max']);
    final minT = List<double>.from(data['temperature_2m_min']);

    final result = <String, dynamic>{};
    for (var i = 0; i < times.length; i++) {
      result[times[i]] = {
        'code': codes[i],
        'tempMax': maxT[i],
        'tempMin': minT[i],
      };
    }

    _cache = result;
    _cacheTime = DateTime.now();
    return result;
  }

  static Map<String, String> codeToInfo(int code) {
    if (code == 0) return {'icon': '☀️', 'text': '晴'};
    if (code <= 3) return {'icon': '⛅', 'text': '多云'};
    if (code <= 48) return {'icon': '🌫️', 'text': '雾'};
    if (code <= 57) return {'icon': '🌦️', 'text': '毛毛雨'};
    if (code <= 67) return {'icon': '🌧️', 'text': '雨'};
    if (code <= 77) return {'icon': '❄️', 'text': '雪'};
    if (code <= 82) return {'icon': '🌧️', 'text': '阵雨'};
    if (code <= 86) return {'icon': '🌨️', 'text': '阵雪'};
    if (code <= 99) return {'icon': '⛈️', 'text': '雷暴'};
    return {'icon': '🌡️', 'text': '未知'};
  }
}
