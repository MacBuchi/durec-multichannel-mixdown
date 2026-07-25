import 'dart:async';

import '../io/platform_shim.dart';
import '../src/rust/api/mixer.dart' as rust;
import 'range_probe.dart';

/// Live preview in the browser.
///
/// There is no cpal in wasm and no synchronous read on a `Blob`, so playback
/// is a pump rather than a device callback: this reads source bytes ahead of
/// the playhead, has Rust mix them ([rust.webPlayerProcess], the same chain
/// the export uses), and drops the finished frames into the ring buffer that
/// the `AudioWorklet` plays from.
///
/// The pump only has to stay *ahead* in wall-clock time, not be real-time
/// safe — mixing runs far faster than playback. When the main isolate stalls
/// anyway, the ring covers it, and [underruns] says how often it did not.
class WebPlayback {
  WebPlayback({
    required this.read,
    required this.fileSize,
    required this.tracks,
    required this.master,
    required this.mastering,
    required this.reference,
    required this.onTick,
    required this.onError,
  });

  final RangeReader read;
  final int fileSize;

  /// Fetched fresh on every push so a fader move takes effect immediately.
  final List<rust.ApiTrack> Function() tracks;
  final rust.ApiMaster Function() master;
  final rust.ApiMixStats? Function() mastering;
  final rust.ApiReferenceProfile? Function() reference;
  final void Function() onTick;

  /// The pump runs detached from any awaiting caller, so a throw here would
  /// otherwise vanish and leave the transport stuck mid-play.
  final void Function(Object error) onError;

  static const _tick = Duration(milliseconds: 40);

  PreviewSink? _sink;
  int? _id;
  Timer? _timer;
  bool _busy = false;

  int _dataStart = 0;
  int _dataEnd = 0;
  int _bytesPerFrame = 0;
  int _sampleRate = 44100;

  /// Next source byte to feed. Runs ahead of what is audible by whatever sits
  /// in the ring.
  int _feedAt = 0;
  int _startFrame = 0;
  int _playedAtStart = 0;

  bool get playing => _sink != null;

  /// Bridge handle, for polling meters.
  int? get playerId => _id;

  /// Frames the device has actually played, absolute in the file.
  ///
  /// The worklet's counter never resets, so a seek records where it stood and
  /// counts from there — otherwise the playhead would keep the frames played
  /// before the jump.
  int get positionFrames => _startFrame + _playedSinceStart;

  double get positionSeconds => positionFrames / _sampleRate;

  int get underruns => _sink?.underruns ?? 0;

  /// True once the whole source has been fed and less is left in the ring
  /// than the worklet can pull.
  ///
  /// Ask the ring, not the counters. "Every written frame played" looks exact
  /// and can never come true: Web Audio pulls whole 128-frame quanta, so a
  /// shorter remainder — measured at 96 frames on a real take — sits there
  /// forever while the worklet underruns. The earlier "ring 90 % empty" erred
  /// the other way and cut the end off.
  bool get finished =>
      _feedAt >= _dataEnd && (_sink?.bufferedSamples ?? 0) < _renderQuantum * 2;

  /// Web Audio's fixed block size, in frames.
  static const _renderQuantum = 128;

  int get _playedSinceStart => (_sink?.playedFrames ?? 0) - _playedAtStart;

  /// Start playing at [fromFrame]. Must be called from a user gesture — iOS
  /// Safari refuses to start an `AudioContext` outside one.
  Future<void> start(int fromFrame) async {
    await stop();
    final chunks = await scanChunksByRanges(read, fileSize);
    final fmt = chunks.where((c) => c.id == 'fmt ').firstOrNull;
    final data = chunks.where((c) => c.id == 'data').firstOrNull;
    if (fmt == null || data == null) {
      throw const FormatException('WAV without fmt/data chunk');
    }
    final fmtChunk = await read(
      fmt.offset.toInt(),
      fmt.offset.toInt() + fmt.size.toInt(),
    );
    final probe = rust.probeFromChunks(
      fmtChunk: fmtChunk,
      ixmlChunk: null,
      dataBytes: data.size,
    );
    _sampleRate = probe.sampleRate;
    _bytesPerFrame = probe.channels * (probe.bitsPerSample ~/ 8);
    _dataStart = data.offset.toInt();
    _dataEnd = _dataStart + data.size.toInt();
    _startFrame = fromFrame;
    _feedAt = _dataStart + fromFrame * _bytesPerFrame;

    final sink = await openPreviewSink(probe.sampleRate);
    if (sink == null) throw StateError('no preview output on this platform');
    _id = await rust.webPlayerBegin(
      fmtChunk: fmtChunk,
      tracks: tracks(),
      master: master(),
      masteringStats: mastering(),
      reference: reference(),
      startFrame: BigInt.from(fromFrame),
    );
    _playedAtStart = sink.playedFrames;
    _sink = sink;
    _timer = Timer.periodic(_tick, (_) => unawaited(_pump()));
  }

  Future<void> _pump() async {
    final sink = _sink;
    final id = _id;
    // Re-entry would interleave two reads into one ring — the pump is
    // async and a tick can fire while the previous one still awaits.
    if (_busy || sink == null || id == null) return;
    _busy = true;
    try {
      final freeFrames = sink.freeSamples ~/ 2;
      if (freeFrames > 0 && _feedAt < _dataEnd) {
        final wantBytes = freeFrames * _bytesPerFrame;
        final stop = (_feedAt + wantBytes).clamp(_feedAt, _dataEnd);
        final bytes = await read(_feedAt, stop);
        _feedAt = stop;
        final mixed = await rust.webPlayerProcess(id: id, bytes: bytes);
        _sink?.write(mixed);
      }
      onTick();
    } catch (e) {
      await stop();
      onError(e);
    } finally {
      _busy = false;
    }
  }

  /// Push changed mix parameters. They become audible once the ring drains,
  /// which is why it is kept short.
  Future<void> pushParams() async {
    final id = _id;
    if (id == null) return;
    await rust.webPlayerUpdateParams(
      id: id,
      tracks: tracks(),
      master: master(),
      masteringStats: mastering(),
      reference: reference(),
    );
  }

  Future<void> seek(int frame) async {
    final id = _id;
    final sink = _sink;
    if (id == null || sink == null) return;
    sink.flush();
    await rust.webPlayerSeek(id: id, frame: BigInt.from(frame));
    _playedAtStart = sink.playedFrames;
    _startFrame = frame;
    _feedAt = _dataStart + frame * _bytesPerFrame;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final sink = _sink;
    _sink = null;
    await sink?.dispose();
    final id = _id;
    _id = null;
    if (id != null) await rust.webPlayerEnd(id: id);
  }
}
