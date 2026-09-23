# On-device voice model (Piper via sherpa-onnx)

This folder is where the app looks for its local, offline text-to-speech
voice (`lib/services/local_tts_service.dart`). Nothing here is bundled by
default — voice model files are large binaries and have their own license
per voice, so they aren't checked into the repo. Until you add them, the app
still works normally: it just falls back to the phone's default system
voice, exactly like before.

## 1. Pick and download a voice

Piper voices packaged for sherpa-onnx are published here:
https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models

The app defaults to **en_US-libritts_r-medium** (a solid, natural-sounding
medium-quality English voice, good real-time speed on phones):

```
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts_r-medium.tar.bz2
tar xf vits-piper-en_US-libritts_r-medium.tar.bz2
```

Any other `vits-piper-*` voice from that same page works too (e.g.
`en_US-lessac-medium`, `en_US-amy-medium`, or a different language) — just
adjust the file name in step 4.

## 2. Copy the files into this folder

You should end up with:

```
assets/tts/en_US-libritts_r-medium.onnx
assets/tts/tokens.txt
assets/tts/espeak-ng-data/...        (a folder of many small files)
```

(`lexicon.txt`, if the voice includes one, is optional — the local service
doesn't require it.)

## 3. Generate the file list

Flutter's asset bundler needs every individual file spelled out — it won't
automatically pick up a directory it's never seen the contents of. From the
project root:

```
find assets/tts -type f ! -name 'manifest.txt' ! -name 'README.md' \
  | sed 's#assets/tts/##' | sort > assets/tts/manifest.txt
```

`local_tts_service.dart` reads this list at runtime to copy the model out of
the app bundle into real files on disk (the synthesis engine needs actual
file paths, not in-memory asset bytes).

If `espeak-ng-data` turns out to contain its own subfolders on your voice,
also add an explicit line for each of them under `flutter: assets:` in
`pubspec.yaml` (next to the two `assets/tts/...` lines already there) —
Flutter only bundles files it's told about at each folder level.

## 4. Point the app at the right file name

If you used a voice other than `en_US-libritts_r-medium`, open
`lib/services/local_tts_service.dart` and update:

```dart
static const String _modelFile = 'en_US-libritts_r-medium.onnx';
```

to match your voice's `.onnx` file name.

## 5. Rebuild

```
flutter pub get
flutter build apk
```

That's it — no server, no network call at runtime. The first time the app
runs after this, it copies the model into app storage once; every synthesis
call after that is instant and fully offline.
