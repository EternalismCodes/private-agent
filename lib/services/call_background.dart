import 'package:flutter/services.dart';

/// Native side of the voice call: a foreground service (type microphone) that
/// lets the app keep listening while other apps are on screen, plus a
/// "Hang up" notification button.
class CallBackground {
  CallBackground._();

  static const MethodChannel _channel = MethodChannel('com.privateagent/call');

  /// Starts (or refreshes) the ongoing call notification/service.
  static Future<bool> start(String text, {String phase = 'listening', bool overlay = false}) async {
    try {
      await _channel.invokeMethod('start', {'text': text, 'phase': phase, 'overlay': overlay});
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> update(String text, {String phase = 'listening'}) async {
    try {
      await _channel.invokeMethod('update', {'text': text, 'phase': phase});
    } catch (_) {}
  }

  static Future<bool> overlayGranted() async {
    try {
      return await _channel.invokeMethod<bool>('overlayGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlay() async {
    try {
      await _channel.invokeMethod('requestOverlay');
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
