import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Switches for the experimental features. Everything defaults to OFF, so the
/// normal app behaves exactly as before until you turn something on.
class LabPrefs {
  LabPrefs._();
  static final LabPrefs instance = LabPrefs._();

  bool _loaded = false;
  bool vision = false;
  bool teach = false;
  String vlmModel = '';
  String vlmBaseUrl = '';
  String vlmKey = '';

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      vision = p.getBool('lab_vision') ?? false;
      teach = p.getBool('lab_teach') ?? false;
      vlmModel = p.getString('lab_vlm_model') ?? '';
      vlmBaseUrl = p.getString('lab_vlm_base') ?? '';
      try {
        vlmKey = await const FlutterSecureStorage().read(key: 'lab_vlm_key') ?? '';
      } catch (_) {}
      _loaded = true;
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('lab_vision', vision);
      await p.setBool('lab_teach', teach);
      await p.setString('lab_vlm_model', vlmModel.trim());
      await p.setString('lab_vlm_base', vlmBaseUrl.trim());
      try {
        await const FlutterSecureStorage().write(key: 'lab_vlm_key', value: vlmKey.trim());
      } catch (_) {}
    } catch (_) {}
  }
}
