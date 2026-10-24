import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Takes a photo directly via Camera2 (see native `SilentCameraCapture`) —
/// no camera-app UI is shown, so there is nothing to accessibility-tap and
/// no OEM camera-app quirks to work around. Works with either the back
/// camera or, for selfies, the front camera.
class CameraService {
  static const MethodChannel _channel = MethodChannel('com.privateagent/camera');

  /// The full path of the most recently taken photo (back or front), kept
  /// so "analyse the photo I just took" can work without the user having
  /// to repeat the path.
  String? lastPhotoPath;

  /// Returns a message describing the result; the saved file path is
  /// embedded in a successful message so it can be surfaced to the user or
  /// picked up by a later step (e.g. "then send it on WhatsApp").
  ///
  /// Set [selfie] to true to use the front camera instead of the back one —
  /// same silent, no-UI capture either way.
  Future<String> takePhoto({bool selfie = false}) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      return 'Could not take a photo: camera permission was not granted. You can enable it from PrivateAgent\'s permissions in Settings.';
    }
    try {
      final path = await _channel
          .invokeMethod<String>('takePhoto', {'front': selfie})
          .timeout(const Duration(seconds: 90));
      if (path == null || path.isEmpty) {
        return 'The camera did not return a photo — it may have been cancelled, or no camera app is available.';
      }
      lastPhotoPath = path;
      return selfie ? 'Took a selfie and saved it to $path.' : 'Took a photo and saved it to $path.';
    } on PlatformException catch (e) {
      return 'Could not take a photo: ${e.message ?? e.code}';
    } on TimeoutException {
      return 'Could not take a photo: timed out waiting for the camera app. Make sure PrivateAgent is in the foreground when this runs.';
    } catch (e) {
      return 'Could not take a photo: $e';
    }
  }
}
