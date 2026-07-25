// Custom bootstrap: loads Flutter WITHOUT registering its own service
// worker.
//
// Only one service worker can own a scope. Flutter's default bootstrap
// registers `flutter_service_worker.js` at "/", which evicts the
// cross-origin-isolation worker (`coi-sw.js`) that the wasm engine depends
// on — and coi-sw.js then evicts Flutter's again. The result is a reload
// ping-pong where the page is isolated on every other load, so the engine
// starts only half the time (docs/PLAN-PWA.md S5).
//
// Offline caching therefore stays unimplemented for now; when it is added,
// it has to live INSIDE coi-sw.js rather than as a second worker.

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load();
