import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

class SoundService {
  AudioPlayer? _player;
  File? _sendFile;
  File? _receiveFile;

  Future<void> init() async {
    final dir = await getTemporaryDirectory();
    _sendFile = File('${dir.path}/send.wav');
    _receiveFile = File('${dir.path}/receive.wav');

    if (!await _sendFile!.exists()) {
      await _sendFile!.writeAsBytes(_generateWav(1000, 80));
    }
    if (!await _receiveFile!.exists()) {
      await _receiveFile!.writeAsBytes(_generateWav(660, 130));
    }

    _player = AudioPlayer(handleInterruptions: false);
  }

  Future<void> playSend() async {
    final f = _sendFile;
    final p = _player;
    if (f == null || p == null) return;
    await p.setAudioSource(AudioSource.file(f.path), preload: false);
    p.play();
  }

  Future<void> playReceive() async {
    final f = _receiveFile;
    final p = _player;
    if (f == null || p == null) return;
    await p.setAudioSource(AudioSource.file(f.path), preload: false);
    p.play();
  }

  void dispose() {
    _player?.dispose();
  }

  Uint8List _generateWav(int frequency, int durationMs) {
    const sampleRate = 44100;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final samples = Int16List(numSamples);
    final durationSec = durationMs / 1000.0;
    const fadeSec = 0.008;

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final envelope = _envelope(t, durationSec, fadeSec);
      samples[i] = (sin(2 * pi * frequency * t) * 16384 * envelope).round();
    }

    final dataSize = numSamples * 2;
    final buffer = ByteData(44 + dataSize);

    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x49);
    buffer.setUint8(2, 0x46);
    buffer.setUint8(3, 0x46);
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    buffer.setUint8(8, 0x57);
    buffer.setUint8(9, 0x41);
    buffer.setUint8(10, 0x56);
    buffer.setUint8(11, 0x45);

    buffer.setUint8(12, 0x66);
    buffer.setUint8(13, 0x6D);
    buffer.setUint8(14, 0x74);
    buffer.setUint8(15, 0x20);
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);

    buffer.setUint8(36, 0x64);
    buffer.setUint8(37, 0x61);
    buffer.setUint8(38, 0x74);
    buffer.setUint8(39, 0x61);
    buffer.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      buffer.setInt16(44 + i * 2, samples[i], Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  double _envelope(double t, double duration, double fade) {
    if (t < fade) return t / fade;
    if (t > duration - fade) return (duration - t) / fade;
    return 1.0;
  }
}
