import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../agent/people_book.dart';
import '../agent/prefs.dart';
import '../agent/walkthrough_book.dart';
import '../lab/lab_prefs.dart';

/// One JSON file with everything PrivateAgent keeps: AI provider/API
/// settings and backup providers, agent preferences, people aliases, learned
/// walkthroughs, favorites, taught tasks, IR codes (all SharedPreferences),
/// plus the files in app storage — memory, skills, schedules, plan cache,
/// task and chat history — so setting up a new phone (or recovering from a
/// reinstall) doesn't mean typing everything back in by hand. Saved logins
/// in the password vault are deliberately NOT included.
///
/// The file contains your API key in plain text (there's no way to restore
/// it later otherwise) — treat it like any other file with a password in
/// it: fine to keep for yourself or move to a new phone, not something to
/// post or send to someone you don't trust.
class BackupResult {
  final bool ok;
  final String message;
  final int? keyCount;
  final File? file;
  const BackupResult(this.ok, this.message, {this.keyCount, this.file});
}

class BackupService {
  static const _marker = 'PrivateAgent';
  static const _version = 2;

  /// Files in the app's documents folder that belong in a backup.
  static const _docFiles = <String>[
    'memory.md',
    'agent_skills.json',
    'skills_memory.jsonl',
    'scheduled_tasks.json',
    'plan_cache.json',
    'task_history.jsonl',
    'chat_history_sessions.json',
  ];

  /// Per-device switches that must not travel between devices.
  static bool _deviceOnly(String key) => key.startsWith('neural_tts_') || key == 'asked_overlay_permission';

  Future<Directory> _backupsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>> _snapshot(SharedPreferences p) async {
    final data = <String, dynamic>{};
    for (final key in p.getKeys()) {
      if (_deviceOnly(key)) continue;
      // SharedPreferences values are always bool/int/double/String/List<String>,
      // all of which round-trip through JSON directly.
      data[key] = p.get(key);
    }
    final files = <String, String>{};
    final docs = await getApplicationDocumentsDirectory();
    for (final name in _docFiles) {
      try {
        final f = File('${docs.path}/$name');
        if (await f.exists()) files[name] = await f.readAsString();
      } catch (_) {}
    }
    final secure = <String, String>{};
    try {
      final v = await const FlutterSecureStorage().read(key: 'lab_vlm_key');
      if (v != null && v.isNotEmpty) secure['lab_vlm_key'] = v;
    } catch (_) {}
    return {
      'app': _marker,
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'prefs': data,
      'files': files,
      'secure': secure,
    };
  }

  /// Writes a backup file into the app's own storage and returns it. Kept
  /// around on-device so "import" can offer it as a one-tap option later
  /// without the user having to go find it again.
  Future<File> exportToFile() async {
    final p = await SharedPreferences.getInstance();
    final map = await _snapshot(p);
    final dir = await _backupsDir();
    final file = File('${dir.path}/privateagent-backup-${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
    return file;
  }

  /// Export + open the share sheet so the user can save it to Downloads,
  /// Drive, email it to themselves, etc.
  Future<BackupResult> exportAndShare() async {
    try {
      final file = await exportToFile();
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'PrivateAgent settings backup'),
      );
      return BackupResult(true, 'Exported to ${file.path}', file: file);
    } catch (e) {
      return BackupResult(false, 'Could not export settings: $e');
    }
  }

  /// Previous backups already saved on this device (newest first) — the
  /// "automatically scans and finds it" option, for restoring on the same
  /// phone or one where the file was already dropped into app storage.
  Future<List<File>> localBackups() async {
    try {
      final dir = await _backupsDir();
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return files;
    } catch (_) {
      return [];
    }
  }

  /// Lets the user pick any backup .json file from storage (Downloads,
  /// Drive-synced folders, wherever they saved or received it).
  Future<File?> pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    final path = result?.files.single.path;
    return path == null ? null : File(path);
  }

  Future<Map<String, dynamic>> _readAndValidate(File file) async {
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['app'] != _marker || decoded['prefs'] is! Map) {
      throw const FormatException('That file is not a PrivateAgent settings backup.');
    }
    return decoded.cast<String, dynamic>();
  }

  /// Restores every key found in the backup, overwriting the current value.
  /// Anything not present in the backup is left exactly as it is.
  Future<BackupResult> importFrom(File file) async {
    try {
      final backup = await _readAndValidate(file);
      final data = (backup['prefs'] as Map).cast<String, dynamic>();
      final p = await SharedPreferences.getInstance();
      var count = 0;
      for (final entry in data.entries) {
        final key = entry.key;
        final value = entry.value;
        try {
          if (_deviceOnly(key)) continue;
          if (value is bool) {
            await p.setBool(key, value);
          } else if (value is int) {
            await p.setInt(key, value);
          } else if (value is double) {
            await p.setDouble(key, value);
          } else if (value is String) {
            await p.setString(key, value);
          } else if (value is List) {
            await p.setStringList(key, value.map((e) => '$e').toList());
          } else {
            continue;
          }
          count++;
        } catch (_) {
          // Skip anything malformed rather than aborting the whole restore.
        }
      }
      var fileCount = 0;
      final files = backup['files'];
      if (files is Map) {
        final docs = await getApplicationDocumentsDirectory();
        for (final name in _docFiles) {
          final content = files[name];
          if (content is String) {
            try {
              await File('${docs.path}/$name').writeAsString(content, flush: true);
              fileCount++;
            } catch (_) {}
          }
        }
      }
      final secure = backup['secure'];
      if (secure is Map && secure['lab_vlm_key'] is String) {
        try {
          await const FlutterSecureStorage().write(key: 'lab_vlm_key', value: secure['lab_vlm_key'] as String);
        } catch (_) {}
      }
      await reloadInMemory();
      return BackupResult(
        true,
        'Restored $count settings and $fileCount data files (memory, skills, schedules, history). Restart PrivateAgent for everything to take effect.',
        keyCount: count,
      );
    } on FormatException catch (e) {
      return BackupResult(false, e.message);
    } catch (e) {
      return BackupResult(false, 'Could not read that backup: $e');
    }
  }

  /// Makes the in-memory copies pick up what a restore just wrote.
  static Future<void> reloadInMemory() async {
    try {
      await AgentPrefs.instance.reload();
      await LabPrefs.instance.reload();
      PeopleBook.instance.reset();
      await PeopleBook.instance.load();
      WalkthroughBook.instance.reset();
      await WalkthroughBook.instance.load();
    } catch (_) {}
  }
}
