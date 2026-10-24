import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

/// One JSON file with everything PrivateAgent has stored via
/// SharedPreferences: AI provider/API settings, agent behaviour prefs,
/// favorites, saved skills, taught tasks, saved IR codes — all of it, so
/// setting up a new phone (or recovering from a reinstall) doesn't mean
/// typing everything back in by hand.
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
  static const _version = 1;

  Future<Directory> _backupsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Map<String, dynamic> _snapshot(SharedPreferences p) {
    final data = <String, dynamic>{};
    for (final key in p.getKeys()) {
      final v = p.get(key);
      // SharedPreferences values are always bool/int/double/String/List<String>,
      // all of which round-trip through JSON directly.
      data[key] = v;
    }
    return {
      'app': _marker,
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'prefs': data,
    };
  }

  /// Writes a backup file into the app's own storage and returns it. Kept
  /// around on-device so "import" can offer it as a one-tap option later
  /// without the user having to go find it again.
  Future<File> exportToFile() async {
    final p = await SharedPreferences.getInstance();
    final map = _snapshot(p);
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
      return BackupResult(true, 'Restored $count settings. Restart PrivateAgent for everything to take effect.', keyCount: count);
    } on FormatException catch (e) {
      return BackupResult(false, e.message);
    } catch (e) {
      return BackupResult(false, 'Could not read that backup: $e');
    }
  }
}
