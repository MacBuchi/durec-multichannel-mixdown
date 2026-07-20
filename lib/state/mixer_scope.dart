import 'package:flutter/widgets.dart';

import 'mixer_state.dart';

/// Injection seam for the app's [MixerState]: the app root owns the state
/// and provides it here; widgets and tests reach it via [MixerScope.of]
/// instead of digging into widget internals. Being an [InheritedNotifier],
/// `of(context)` also subscribes the caller to rebuilds on [MixerState]
/// notifications.
class MixerScope extends InheritedNotifier<MixerState> {
  const MixerScope({super.key, required MixerState state, required super.child})
    : super(notifier: state);

  static MixerState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MixerScope>();
    assert(scope != null, 'MixerScope missing above this context');
    return scope!.notifier!;
  }
}
