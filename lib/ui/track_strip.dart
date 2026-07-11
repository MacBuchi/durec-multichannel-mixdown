import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/rust/api/mixer.dart' as rust;
import '../state/mixer_state.dart';
import 'waveform.dart';

/// One track row: toggles, pan, fader, mini waveform.
/// Lays out as a single row on wide screens and a two-line card on phones.
class TrackStrip extends StatelessWidget {
  const TrackStrip({
    super.key,
    required this.state,
    required this.track,
    this.waveform,
  });

  final MixerState state;
  final TrackUi track;
  final rust.ApiChannelWaveform? waveform;

  double get _gainLinear =>
      track.gainDb <= -60 ? 0.0 : math.pow(10, track.gainDb / 20).toDouble();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700;
            return wide ? _wideRow(context) : _narrowCard(context);
          },
        ),
      ),
    );
  }

  Widget _wideRow(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 28, child: Text('${track.index}', style: _dim(context))),
        SizedBox(width: 150, child: _name(context)),
        _toggles(),
        const SizedBox(width: 8),
        _panControl(context, width: 110),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: _gainControl(context)),
        const SizedBox(width: 8),
        SizedBox(width: 180, child: _waveform()),
      ],
    );
  }

  Widget _narrowCard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: 24, child: Text('${track.index}', style: _dim(context))),
            Expanded(child: _name(context)),
            _toggles(),
          ],
        ),
        Row(
          children: [
            _panControl(context, width: 110),
            const SizedBox(width: 8),
            Expanded(child: _gainControl(context)),
          ],
        ),
        SizedBox(height: 36, width: double.infinity, child: _waveform()),
      ],
    );
  }

  TextStyle _dim(BuildContext context) => TextStyle(
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
    fontSize: 12,
  );

  Widget _name(BuildContext context) => Text(
    track.name,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontWeight: FontWeight.w500,
      color: track.inMix
          ? null
          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
    ),
  );

  Widget _toggles() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _toggleChip('ø', track.polarityInvert, Colors.purpleAccent,
            () => state.togglePolarity(track), 'Polarity invert'),
        _toggleChip('M', track.muted, Colors.redAccent,
            () => state.toggleMute(track), 'Mute'),
        _toggleChip('S', track.solo, Colors.amber,
            () => state.toggleSolo(track), 'Solo'),
        _toggleChip('mix', track.inMix, Colors.greenAccent,
            () => state.toggleInMix(track), 'Include in mixdown'),
      ],
    );
  }

  Widget _toggleChip(
      String label, bool on, Color color, VoidCallback onTap, String tip) {
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: on ? color.withValues(alpha: 0.25) : null,
              border: Border.all(
                  color: on ? color : Colors.white24, width: on ? 1.2 : 0.8),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: on ? color : Colors.white38,
                )),
          ),
        ),
      ),
    );
  }

  Widget _panControl(BuildContext context, {required double width}) {
    final label = track.pan.abs() < 0.01
        ? 'C'
        : track.pan < 0
            ? 'L${(track.pan.abs() * 100).round()}'
            : 'R${(track.pan * 100).round()}';
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onDoubleTap: () => state.updateTrack(track, (t) => t.pan = 0),
              child: Slider(
                value: track.pan,
                min: -1,
                max: 1,
                onChanged: (v) => state.updateTrack(track, (t) => t.pan = v),
              ),
            ),
          ),
          SizedBox(width: 26, child: Text(label, style: _dim(context))),
        ],
      ),
    );
  }

  Widget _gainControl(BuildContext context) {
    final label = track.gainDb <= -60
        ? '−∞'
        : '${track.gainDb >= 0 ? '+' : ''}${track.gainDb.toStringAsFixed(1)} dB';
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onDoubleTap: () => state.updateTrack(track, (t) => t.gainDb = 0),
            child: Slider(
              value: track.gainDb,
              min: -60,
              max: 6,
              onChanged: (v) => state.updateTrack(track, (t) => t.gainDb = v),
            ),
          ),
        ),
        SizedBox(width: 58, child: Text(label, style: _dim(context))),
      ],
    );
  }

  Widget _waveform() {
    final w = waveform;
    if (w == null) return const SizedBox.shrink();
    return WaveformView(
      min: w.min,
      max: w.max,
      gainLinear: _gainLinear,
      active: track.inMix && !track.muted,
    );
  }
}
