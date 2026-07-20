import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/rust/api/mixer.dart' as rust;
import '../state/mixer_state.dart';
import 'app_colors.dart';
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
    final eqOpen = state.expandedEq.contains(track.index);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700;
            final row = wide ? _wideRow(context) : _narrowCard(context);
            if (!eqOpen) return row;
            return Column(children: [row, _eqPanel(context)]);
          },
        ),
      ),
    );
  }

  Widget _wideRow(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text('${track.index}', style: _dim(context)),
        ),
        SizedBox(width: 150, child: _name(context)),
        _toggles(context),
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
            SizedBox(
              width: 24,
              child: Text('${track.index}', style: _dim(context)),
            ),
            Expanded(child: _name(context)),
            _toggles(context),
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

  Widget _toggles(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _toggleChip(
          context,
          'ø',
          track.polarityInvert,
          AppColors.of(context).polarity,
          () => state.togglePolarity(track),
          'Polarity invert',
        ),
        _toggleChip(
          context,
          'M',
          track.muted,
          AppColors.of(context).error,
          () => state.toggleMute(track),
          'Mute',
        ),
        _toggleChip(
          context,
          'S',
          track.solo,
          AppColors.of(context).solo,
          () => state.toggleSolo(track),
          'Solo',
        ),
        _toggleChip(
          context,
          'mix',
          track.inMix,
          AppColors.of(context).inMix,
          () => state.toggleInMix(track),
          'Include in mixdown',
        ),
        _toggleChip(
          context,
          'EQ',
          track.eq.isActive,
          AppColors.of(context).accent,
          () => state.toggleEqPanel(track),
          'HPF + 3-band EQ',
        ),
        if (state.linkPairs && state.isPaired(track)) _pairLinkChip(context),
      ],
    );
  }

  /// Per-pair link toggle, shown only while global pair linking is on.
  Widget _pairLinkChip(BuildContext context) {
    final linked = state.isPairLinked(track);
    return Tooltip(
      message: linked
          ? 'Unlink this stereo pair (edit L/R independently)'
          : 'Relink this stereo pair (copies this side to the partner)',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => state.togglePairLink(track),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Icon(
            linked ? Icons.link : Icons.link_off,
            size: 16,
            color: linked
                ? AppColors.of(context).accent
                : AppColors.of(context).faint,
          ),
        ),
      ),
    );
  }

  // ── EQ panel ──────────────────────────────────────────────────────────────

  /// Log-frequency slider mapping.
  static double _toLog(double f, double lo, double hi) =>
      (math.log(f / lo) / math.log(hi / lo)).clamp(0.0, 1.0);
  static double _fromLog(double v, double lo, double hi) =>
      lo * math.pow(hi / lo, v).toDouble();

  Widget _eqPanel(BuildContext context) {
    final eq = track.eq;
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 2, bottom: 4),
      child: Column(
        children: [
          _eqRow(
            context,
            label: 'HPF',
            enabled: eq.hpfEnabled,
            onEnabled: (v) =>
                state.updateTrack(track, (t) => t.eq.hpfEnabled = v),
            freq: eq.hpfFreq,
            freqLo: 20,
            freqHi: 500,
            onFreq: (v) => state.updateTrack(track, (t) => t.eq.hpfFreq = v),
            trailing: SegmentedButton<rust.ApiHpfSlope>(
              style: const ButtonStyle(
                visualDensity: VisualDensity(horizontal: -4, vertical: -4),
              ),
              segments: const [
                ButtonSegment(value: rust.ApiHpfSlope.db12, label: Text('12')),
                ButtonSegment(value: rust.ApiHpfSlope.db24, label: Text('24')),
              ],
              selected: {eq.hpfSlope},
              onSelectionChanged: (s) =>
                  state.updateTrack(track, (t) => t.eq.hpfSlope = s.first),
            ),
          ),
          _bandRow(context, 'Low', eq.low, 40, 500),
          _bandRow(context, 'Mid', eq.mid, 200, 8000),
          _bandRow(context, 'High', eq.high, 1500, 16000),
        ],
      ),
    );
  }

  Widget _bandRow(
    BuildContext context,
    String label,
    EqBandUi band,
    double lo,
    double hi,
  ) {
    return _eqRow(
      context,
      label: label,
      enabled: band.enabled,
      onEnabled: (v) => state.updateTrack(track, (_) => band.enabled = v),
      freq: band.freq,
      freqLo: lo,
      freqHi: hi,
      onFreq: (v) => state.updateTrack(track, (_) => band.freq = v),
      gainDb: band.gainDb,
      onGain: (v) => state.updateTrack(track, (_) => band.gainDb = v),
    );
  }

  Widget _eqRow(
    BuildContext context, {
    required String label,
    required bool enabled,
    required ValueChanged<bool> onEnabled,
    required double freq,
    required double freqLo,
    required double freqHi,
    required ValueChanged<double> onFreq,
    double? gainDb,
    ValueChanged<double>? onGain,
    Widget? trailing,
  }) {
    final freqLabel = freq >= 1000
        ? '${(freq / 1000).toStringAsFixed(1)}k'
        : freq.round().toString();
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: InkWell(
            onTap: () => onEnabled(!enabled),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: enabled
                    ? AppColors.of(context).accent
                    : AppColors.of(context).faint,
              ),
            ),
          ),
        ),
        Switch(
          value: enabled,
          onChanged: onEnabled,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        Expanded(
          child: Slider(
            value: _toLog(freq, freqLo, freqHi),
            onChanged: enabled
                ? (v) => onFreq(_fromLog(v, freqLo, freqHi))
                : null,
          ),
        ),
        SizedBox(width: 54, child: Text('$freqLabel Hz', style: _dim(context))),
        if (gainDb != null && onGain != null) ...[
          Expanded(
            child: GestureDetector(
              onDoubleTap: () => onGain(0),
              child: Slider(
                value: gainDb.clamp(-15, 15),
                min: -15,
                max: 15,
                onChanged: enabled ? onGain : null,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${gainDb >= 0 ? '+' : ''}${gainDb.toStringAsFixed(1)} dB',
              style: _dim(context),
            ),
          ),
        ],
        if (trailing != null) ...[trailing, const SizedBox(width: 8)],
      ],
    );
  }

  Widget _toggleChip(
    BuildContext context,
    String label,
    bool on,
    Color color,
    VoidCallback onTap,
    String tip,
  ) {
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
                color: on ? color : AppColors.of(context).outline,
                width: on ? 1.2 : 0.8,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: on ? color : AppColors.of(context).faint,
              ),
            ),
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
          SizedBox(width: 34, child: Text(label, style: _dim(context))),
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
