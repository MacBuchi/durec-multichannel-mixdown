/// Platform shim: every `dart:io` / plugin capability the app needs, behind
/// one conditional import so shared code compiles for the web too
/// (docs/PLAN-PWA.md, S1).
///
/// Native keeps today's behaviour (`platform_shim_io.dart`). The web build
/// (`platform_shim_web.dart`) boots with an in-memory app container and no
/// network; real web storage and fetch come with later PWA stages.
///
/// Shared code must not import `dart:io`, `path_provider` or `ota_update`
/// directly — those imports are exactly what breaks `flutter build web`.
library;

export 'platform_shim_types.dart';
export 'platform_shim_io.dart'
    if (dart.library.js_interop) 'platform_shim_web.dart';
