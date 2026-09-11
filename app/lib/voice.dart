import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api.dart';
import 'app_state.dart';

/// Speech in and out, through the console backend's `/voice` routes (Sarvam AI).
///
/// Everything here is optional. When the server has no Sarvam key configured,
/// `AppState.voice.configured` is false and the UI never constructs a recording — so an
/// unconfigured server degrades to an ordinary text chat rather than showing broken controls.
///
/// This is the only part of the app that touches device hardware, and the only place that
/// needs a runtime permission. If it has to be removed, deleting this file and the two
/// packages leaves chat working.
class Voice {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _recordingPath;

  /// Begin recording. Returns false when the microphone permission was refused, which is a
  /// normal answer rather than an error — the caller tells the user and carries on.
  Future<bool> startRecording() async {
    try {
      if (!await _recorder.hasPermission()) return false;
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/question.wav';
      // WAV rather than the smaller compressed formats: the transcription endpoint takes raw
      // audio, and a phone-length question is small enough that the size does not matter.
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1, sampleRate: 16000),
        path: path,
      );
      _recordingPath = path;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stop recording and, unless [keep] is false, send the audio for transcription.
  ///
  /// [keep] is false when the user slides away mid-hold to cancel — the recording is still
  /// stopped and deleted, it is simply never uploaded.
  Future<String?> stopAndTranscribe(AppState state, {required bool keep}) async {
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      return null;
    }
    path ??= _recordingPath;
    _recordingPath = null;
    if (path == null) return null;

    final file = File(path);
    try {
      if (!keep) return null;
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return await state.api.transcribe(bytes, languageCode: state.voice.defaultLanguage);
    } on OfflineException {
      return null;
    } on ApiException {
      return null;
    } finally {
      // The audio has served its purpose either way; do not leave recordings on the device.
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // A file we cannot delete is not worth failing the interaction over.
        }
      }
    }
  }

  /// Read [text] aloud. Best-effort: a failure here should never interrupt the conversation.
  Future<void> speak(AppState state, String text) async {
    if (!state.voice.configured || text.trim().isEmpty) return;
    try {
      final wav = await state.api.speak(
        text,
        languageCode: state.voice.defaultLanguage,
        speaker: state.voice.defaultSpeaker,
      );
      await _player.stop();
      await _player.play(BytesSource(_bytes(wav)));
    } catch (_) {
      // Silent by design — the answer is already on screen to read.
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _player.stop();
    } catch (_) {
      // Nothing playing.
    }
  }

  void dispose() {
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
  }
}

/// `audioplayers` wants a `Uint8List`; the HTTP layer hands back `List<int>`.
Uint8List _bytes(List<int> data) => data is Uint8List ? data : Uint8List.fromList(data);
