import 'package:flutter/services.dart';

/// Native side of the voice call: a foreground service (type microphone) that
/// lets the app keep listening while other apps are on screen, plus a
/// "Hang up" notification button.
class CallBackground {
  CallBackground._();

  static const MethodChannel _channel = MethodChannel('com.privateagent/call');

  /// Starts (or refreshes) the ongoing call notification/service.
  static Future<bool> start(String text) async {
    try {
      await _channel.invokeMethod('start', {'text': text});
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> update(String text) async {
    try {
      await _channel.invokeMethod('update', {'text': text});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Sends PrivateAgent to the background without closing it.
  static Future<void> minimize() async {
    try {
      await _channel.invokeMethod('minimize');
    } catch (_) {}
  }

  /// Called when the user taps "Hang up" in the notification.
  static void onHangup(void Function()? callback) {
    if (callback == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'hangup') callback();
      return null;
    });
  }
}
