import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class TaskHistoryLogger {
  static Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/task_history.jsonl');
  }

  /// Appends a task execution record to the history file
  static Future<void> logTask(
    String goal,
    String status,
    int totalTokens,
    int steps,
    List<String> trace, {
    String? mode,
    Map<String, dynamic>? plan,
  }) async {
    try {
      final file = await _localFile;
      
      final data = {
        "goal": goal.trim(),
        "status": status, // "Success", "Failed", "Cancelled"
        "total_tokens": totalTokens,
        "steps_taken": steps,
        "trace": trace,
        "timestamp": DateTime.now().toIso8601String(),
        if (mode != null) "mode": mode,
        if (plan != null) "plan": plan,
      };
      
      await file.writeAsString('${jsonEncode(data)}\n', mode: FileMode.append);
    } catch (e) {
      print('Failed to write task history: $e');
    }
  }

  /// Reads the entire task history file for previewing
  static Future<List<Map<String, dynamic>>> readHistory() async {
    try {
      final file = await _localFile;
      if (!await file.exists()) return [];

      final lines = await file.readAsLines();
      return lines
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList()
          .reversed
          .toList(); // newest first
    } catch (e) {
      print('Failed to read task history: $e');
      return [];
    }
  }

  /// Clears the task history file
  static Future<void> clearHistory() async {
    try {
      final file = await _localFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Failed to clear task history: $e');
    }
  }

  /// Calculates analytics from task history
  static Future<Map<String, dynamic>> getAnalytics() async {
    final history = await readHistory();
    if (history.isEmpty) {
      return {
        'totalTasks': 0,
        'successRate': 0.0,
        'successCount': 0,
        'failedCount': 0,
      };
    }

    int successCount = 0;
    int failedCount = 0;

    for (final task in history) {
      if (task['status'] == 'Success') {
        successCount++;
      } else if (task['status'] == 'Failed' || task['status'] == 'Cancelled') {
        failedCount++;
      }
    }

    return {
      'totalTasks': history.length,
      'successRate': successCount / history.length,
      'successCount': successCount,
      'failedCount': failedCount,
    };
  }
}
