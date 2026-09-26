import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Takes a photo with the device's own Camera app (a standard
/// ACTION_IMAGE_CAPTURE intent writing into a FileProvider-shared file),
/// rather than accessibility-tapping an arbitrary OEM camera UI. Camera
/// shutter buttons are very often custom views with no reliable click
/// semantics — the same class of element Teach mode/the screen agent can
/// miss — so letting the real camera app do the actual capture is far more
/// reliable across phones than trying to automate its screen.
class CameraService {
  static const MethodChannel _channel = MethodChannel('com.privateagent/camera');

  /// Returns a message describing the result; the saved file path is
  /// embedded in a successful message so it can be surfaced to the user or
  /// picked up by a later step (e.g. "then send it on WhatsApp").
  Future<String> takePhoto() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      return 'Could not take a photo: camera permission was not granted. You can enable it from PrivateAgent\'s permissions in Settings.';
    }
    try {
      final path = await _channel.invokeMethod<String>('takePhoto').timeout(const Duration(seconds: 90));
      if (path == null || path.isEmpty) {
        return 'The camera did not return a photo — it may have been cancelled, or no camera app is available.';
      }
      return 'Took a photo and saved it to $path.';
    } on PlatformException catch (e) {
      return 'Could not take a photo: ${e.message ?? e.code}';
    } on TimeoutException {
      return 'Could not take a photo: timed out waiting for the camera app. Make sure PrivateAgent is in the foreground when this runs.';
    } catch (e) {
      return 'Could not take a photo: $e';
    }
  }
}
