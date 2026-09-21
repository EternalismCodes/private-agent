import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:developer' as developer;

/// Dart bridge to the native AccessibilityService.
/// Provides screen reading, UI element interaction, and gesture control.
class ScreenAutomationService {
  static const _channel = MethodChannel('com.privateagent/accessibility');
  static const _channelTimeout = Duration(seconds: 3);

  static Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) {
    return _channel
        .invokeMethod<T>(method, arguments)
        .timeout(_channelTimeout, onTimeout: () {
      throw TimeoutException(
        'Accessibility channel did not reply to $method within '
        '${_channelTimeout.inSeconds}s',
      );
    });
  }

  /// Verifies that this Flutter engine owns a responsive native channel.
  Future<bool> waitUntilReady() async {
    try {
      return await _invoke<bool>('ping') ?? false;
    } catch (e) {
      developer.log('Accessibility channel readiness check failed: $e',
          name: 'PrivateAgent');
      return false;
    }
  }

  /// Log a message to Android's native Log system
  static Future<void> logToNative(String message) async {
    try {
      await _invoke<bool>('logToNative', {'message': message});
    } catch (_) {}
  }

  /// Check if the accessibility service is running
  Future<bool> isServiceRunning() async {
    await logToNative("[ScreenAutomationService] isServiceRunning() CALLED");
    try {
      await logToNative("[ScreenAutomationService] invoking method isServiceRunning...");
      final result = await _invoke<bool>('isServiceRunning') ?? false;
      await logToNative("[ScreenAutomationService] isServiceRunning result = $result");
      return result;
    } catch (e) {
      await logToNative("[ScreenAutomationService] isServiceRunning ERROR = $e");
      return false;
    }
  }

  /// Open Android accessibility settings so user can enable the service
  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  /// Dump the current screen — returns a list of UI elements
  /// Each element has: text, contentDescription, className, isClickable,
  /// isEditable, isScrollable, bounds, index, depth
  Future<List<Map<String, dynamic>>> dumpScreen() async {
    try {
      final result = await _channel.invokeMethod<List>('dumpScreen');
      if (result == null) return [];
      return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      return [];
    }
  }

  /// Take a screenshot and return it as a Base64 encoded string.
  /// Note: Requires Android 11 (API 30) or higher.
  Future<String?> takeScreenshot() async {
    try {
      final result = await _channel.invokeMethod<String>('takeScreenshot');
      return result;
    } catch (e) {
      return null;
    }
  }

  /// Get a simplified text description of the current screen for the LLM
  Future<String> getScreenDescription() async {
    final nodes = await dumpScreen();
    if (nodes.isEmpty) {
      return 'Could not read screen. Make sure accessibility service is enabled.';
    }

    final buffer = StringBuffer();
    final pkg = await getCurrentPackage();
    if (pkg != null) {
      buffer.writeln('Current app: $pkg');
    }
    buffer.writeln('Screen elements:');

    int count = 0;
    // Limit removed as requested by user. Kotlin now filters invisibles, so this is safe.

    for (final node in nodes) {
      final index = node['index'];
      final text = node['text'] ?? '';
      final desc = node['contentDescription'] ?? '';
      final className = node['className'] ?? '';
      final isClickable = node['isClickable'] == true;
      final isEditable = node['isEditable'] == true;
      final isScrollable = node['isScrollable'] == true;

      String displayText = text.isNotEmpty ? text : desc;
      if (displayText.isEmpty && !isClickable && !isEditable && !isScrollable) {
        continue; // Skip empty non-interactive nodes
      }

      // Truncate very long text to save tokens
      if (displayText.length > 200) {
        displayText = '${displayText.substring(0, 200)}...';
      }

      final tags = <String>[];
      if (isClickable) tags.add('clickable');
      if (isEditable) tags.add('editable');
      if (isScrollable) tags.add('scrollable');

      final label = displayText.isNotEmpty ? '"$displayText"' : '(no text)';
      final type = className.isNotEmpty ? '[$className]' : '';
      final tagStr = tags.isNotEmpty ? '{${tags.join(", ")}}' : '';
      
      String boundsStr = '';
      if (node['bounds'] != null) {
        final b = node['bounds'];
        final centerX = (b['left'] + b['right']) / 2;
        final centerY = (b['top'] + b['bottom']) / 2;
        boundsStr = ' bounds:[${b['left']},${b['top']},${b['right']},${b['bottom']}] center:(${centerX.round()},${centerY.round()})';
      }

      buffer.writeln('  [$index] $type $label $tagStr$boundsStr');
      count++;
    }

    return buffer.toString();
  }

  /// Get a highly compressed text description of the screen for the LLM
  Future<String> getCompressedScreenDescription(String task) async {
    final nodes = await dumpScreen();
    if (nodes.isEmpty) {
      return 'Could not read screen. Make sure accessibility service is enabled.';
    }

    final buffer = StringBuffer();
    final pkg = await getCurrentPackage();
    if (pkg != null) {
      buffer.writeln('APP: $pkg');
    }
    
    // Extract task keywords for highlighting
    final stopWords = {'to', 'and', 'the', 'a', 'in', 'of', 'for', 'on', 'with', 'at', 'by', 'from', 'go', 'turn', 'open'};
    final keywords = task.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !stopWords.contains(w)).toList();

    for (final node in nodes) {
      final index = node['index'];
      final text = node['text'] ?? '';
      final desc = node['contentDescription'] ?? '';
      final className = node['className'] ?? '';
      final isClickable = node['isClickable'] == true;
      final isEditable = node['isEditable'] == true;
      final isScrollable = node['isScrollable'] == true;

      String displayText = text.isNotEmpty ? text : desc;
      final lowerText = displayText.toLowerCase();
      
      // Skip status bar items and internal controls
      if (lowerText.contains('battery') || 
          lowerText.contains('percent') ||
          lowerText.contains('do not disturb') ||
          lowerText.contains('three bars') ||
          lowerText == '🛑 stop macro' ||
          lowerText == 'stop macro' ||
          RegExp(r'^\d{1,2}:\d{2}$').hasMatch(lowerText)) { // time
        continue;
      }

      if (displayText.isEmpty && !isClickable && !isEditable && !isScrollable) {
        continue; // Skip empty non-interactive nodes
      }

      // Truncate very long text to save tokens
      if (displayText.length > 50) {
        displayText = '${displayText.substring(0, 50)}...';
      }

      final tags = <String>[];
      if (isClickable) tags.add('tap');
      if (isEditable) tags.add('edit');
      if (isScrollable) tags.add('scroll');

      // Simplify type
      String type = className.split('.').last;
      if (type == 'TextView') type = 'text';
      else if (type == 'Button') type = 'btn';
      else if (type == 'Switch') type = 'toggle';
      else if (type == 'ImageView') type = 'img';
      else if (type == 'EditText') type = 'input';
      else if (type == 'FrameLayout' || type == 'LinearLayout') type = 'view';
      else type = type.toLowerCase();

      final label = displayText.isNotEmpty ? '"$displayText"' : '';
      final tagStr = tags.isNotEmpty ? '[${tags.join(",")}]' : '';
      
      // Highlight if matches task
      bool isTarget = false;
      if (displayText.isNotEmpty) {
        for (var kw in keywords) {
          if (lowerText.contains(kw)) {
            isTarget = true;
            break;
          }
        }
      }
      
      final targetMark = isTarget ? '*' : '';

      String boundsStr = '';
      if (node['bounds'] != null) {
        final b = node['bounds'];
        final centerX = (b['left'] + b['right']) / 2;
        final centerY = (b['top'] + b['bottom']) / 2;
        boundsStr = ' center:(${centerX.round()},${centerY.round()})';
      }

      buffer.writeln('[$index]$targetMark $type $label $tagStr$boundsStr'.trim().replaceAll(RegExp(r'\s+'), ' '));
    }

    final screenString = buffer.toString();
    developer.log('Screen Dump Extracted:\n$screenString', name: 'ScreenAutomation');
    return screenString;
  }

  /// Click an element by its visible text
  Future<bool> clickByText(String text) async {
    try {
      return await _channel.invokeMethod<bool>('clickByText', {'text': text}) ??
          false;
    } catch (e) {
      return false;
    }
  }

  /// Click at specific screen coordinates
  Future<bool> clickAt(double x, double y) async {
    try {
      return await _channel
              .invokeMethod<bool>('clickAt', {'x': x, 'y': y}) ??
          false;
    } catch (e) {
      return false;
    }
  }

  /// Type text into an editable field
  Future<bool> typeText(String text, {String? fieldHint}) async {
    try {
      return await _channel.invokeMethod<bool>(
              'typeText', {'text': text, 'fieldHint': fieldHint}) ??
          false;
    } catch (e) {
      return false;
    }
  }

  /// Press the Enter/Search key on the keyboard
  Future<bool> pressEnter() async {
    try {
      return await _channel.invokeMethod<bool>('pressEnter') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Scroll in a direction ("down", "up")
  Future<bool> scroll(String direction, {String? target}) async {
    try {
      return await _channel.invokeMethod<bool>(
              'scroll', {'direction': direction, 'target': target}) ??
          false;
    } catch (e) {
      return false;
    }
  }

  /// Swipe from one point to another
  Future<bool> swipe(
      double startX, double startY, double endX, double endY) async {
    try {
      return await _channel.invokeMethod<bool>('swipe', {
            'startX': startX,
            'startY': startY,
            'endX': endX,
            'endY': endY,
          }) ??
          false;
    } catch (e) {
      return false;
    }
  }

  /// Press the back button
  Future<bool> pressBack() async {
    try {
      return await _channel.invokeMethod<bool>('pressBack') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Press the home button
  Future<bool> pressHome() async {
    try {
      return await _channel.invokeMethod<bool>('pressHome') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Show a native Android Toast message
  Future<void> showToast(String message) async {
    try {
      await _channel.invokeMethod('showToast', {'message': message});
    } catch (e) {
      // ignore
    }
  }

  /// Open notifications panel
  Future<bool> openNotifications() async {
    try {
      return await _channel.invokeMethod<bool>('openNotifications') ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Get current foreground app package name
  Future<String?> getCurrentPackage() async {
    try {
      return await _channel.invokeMethod<String>('getCurrentPackage');
    } catch (e) {
      return null;
    }
  }
}
