import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// On-device neural text-to-speech: a Piper voice run locally through
/// sherpa-onnx (ONNX Runtime). Nothing is sent over the network and no
/// server has to be running — synthesis happens on the phone's CPU, and for
/// a sentence or two it finishes in well under a second, faster than most
/// people can read the reply. The voice is noticeably more natural than the
/// phone's default system TTS (which is typically a compact, robotic
/// offline engine), while still being fully offline itself.
///
/// SETUP (one-time, done by whoever builds the app — see assets/tts/README.md):
/// 1. Download a Piper voice packaged for sherpa-onnx, e.g.
///    vits-piper-en_US-libritts_r-medium.tar.bz2 from
///    https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models
/// 2. Extract it into assets/tts/ so the layout looks like:
///      assets/tts/en_US-libritts_r-medium.onnx
///      assets/tts/tokens.txt
///      assets/tts/espeak-ng-data/... (lots of small files)
/// 3. Generate the file list sherpa-onnx's own Flutter examples also need
///    (Flutter's asset bundler needs to be told about every individual
///    file): from the project root,
///      find assets/tts -type f ! -name 'manifest.txt' ! -name 'README.md' \
///        | sed 's#assets/tts/##' | sort > assets/tts/manifest.txt
/// 4. If you picked a different voice than the one above, update
///    [_modelFile] below to match its .onnx file name.
///
/// If those files aren't bundled, [init] returns false and every caller in
/// this app falls back to the phone's normal system voice — this class
/// never throws or crashes the app for a missing/misconfigured model.
class LocalTtsService {
  LocalTtsService._();
  static final LocalTtsService instance = LocalTtsService._();

  static const String _assetDir = 'assets/tts';
  // Change this to match whichever Piper voice you bundle in assets/tts/.
  static const String _modelFile = 'en_US-libritts_r-medium.onnx';
  static const String _tokensFile = 'tokens.txt';
  static const String _dataDirName = 'espeak-ng-data';

  sherpa_onnx.OfflineTts? _tts;
  bool _initTried = false;
  bool _bindingsInit = false;

  bool get isAvailable => _tts != null;

  /// Sets everything up: copies the bundled model into app storage (once)
  /// and loads it. Safe to call repeatedly — later calls are instant once
  /// the first one has finished. Returns false if the model isn't bundled
  /// or fails to load, never throws.
  Future<bool> init() async {
    if (_initTried) return isAvailable;
    _initTried = true;
    try {
      final support = await getApplicationSupportDirectory();
      final root = '${support.path}/local_tts_model';
      final modelPath = '$root/$_modelFile';
      final tokensPath = '$root/$_tokensFile';
      final dataDirPath = '$root/$_dataDirName';

      final haveFiles = await File(modelPath).exists() && await File(tokensPath).exists();
      if (!haveFiles) {
        final copied = await _copyModelFromAssets(root);
        if (!copied) return false;
      }
      if (!await File(modelPath).exists() || !await File(tokensPath).exists()) {
        return false;
      }

      if (!_bindingsInit) {
        sherpa_onnx.initBindings();
        _bindingsInit = true;
      }

      final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: modelPath,
        tokens: tokensPath,
        lexicon: '',
        dataDir: Directory(dataDirPath).existsSync() ? dataDirPath : '',
      );
      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: vits,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
      _tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(model: modelConfig));
      return true;
    } catch (_) {
      _tts = null;
      return false;
    }
  }

  /// Copies every asset file listed in assets/tts/manifest.txt (one
  /// relative path per line) from the app bundle into app storage — the
  /// synthesis engine needs real files on disk, it can't read straight out
  /// of the Flutter asset bundle. Returns false (without throwing) if the
  /// manifest or model isn't there, which just means the model was never
  /// set up.
  Future<bool> _copyModelFromAssets(String destRoot) async {
    try {
      final manifest = await rootBundle.loadString('$_assetDir/manifest.txt');
      final files = manifest
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'));
      var any = false;
      for (final relative in files) {
        try {
          final data = await rootBundle.load('$_assetDir/$relative');
          final outFile = File('$destRoot/$relative');
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
          any = true;
        } catch (_) {
          // One missing/renamed file shouldn't block the rest.
        }
      }
      return any;
    } catch (_) {
      return false; // no manifest.txt => model was never bundled/set up
    }
  }

  /// Synthesizes [text] and returns 16-bit PCM WAV bytes ready to hand to
  /// AudioPlayback.playAndWait, or null if the local voice isn't set up or
  /// synthesis failed for any reason (callers should fall back to the
  /// system voice in that case).
  Future<Uint8List?> synthesizeToWav(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    if (!isAvailable && !await init()) return null;

    try {
      final audio = _tts!.generate(text: clean, sid: 0, speed: 1.0);
      if (audio.samples.isEmpty) return null;

      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}/local_tts_${DateTime.now().microsecondsSinceEpoch}.wav';
      final wrote = sherpa_onnx.writeWave(
        filename: path,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      if (!wrote) return null;

      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _tts?.free();
    _tts = null;
  }
}
