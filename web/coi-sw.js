// Cross-origin-isolation service worker — and the app's offline cache.
//
// The Rust engine runs as threaded wasm, which needs SharedArrayBuffer,
// which the browser only grants to a cross-origin-isolated page — that is,
// one served with COOP `same-origin` and COEP `require-corp`. GitHub Pages
// serves static files and cannot set custom headers, so this worker adds
// them to every response it proxies. Without it the app dies at startup
// with "DataCloneError: #<Memory> could not be cloned" (docs/PLAN-PWA.md).
//
// Everything the app loads is same-origin (Flutter bundle, wasm, assets),
// so no cross-origin resource needs a CORP header. Keep it that way: an
// external font or CDN script would be blocked by COEP.
//
// **The offline cache lives here on purpose.** Only one service worker can
// own a scope, so a second worker for caching would evict this one and get
// evicted in turn — a reload ping-pong where the page is isolated on every
// other load and the engine starts half the time. That is why
// `web/flutter_bootstrap.js` also loads Flutter without its own worker.
//
// Registered from index.html, which reloads once so this worker controls
// the page.

// Bump to discard everything cached by an older worker.
const CACHE = 'durecmix-v1';

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) =>
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names.filter((n) => n !== CACHE).map((n) => caches.delete(n)),
      );
      await self.clients.claim();
    })(),
  ),
);

/// Same response, plus the headers that make the page cross-origin isolated.
/// Building a new Response consumes `response.body`, so callers that need
/// the bytes twice must clone first.
function harden(response) {
  const headers = new Headers(response.headers);
  headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
  headers.set('Cross-Origin-Opener-Policy', 'same-origin');
  headers.set('Cross-Origin-Resource-Policy', 'same-origin');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/// Worth keeping for an offline start: our own files, fetched whole.
///
/// Partial (206) and error responses are deliberately excluded — a cached
/// 206 would be served as if it were the complete file.
function isCacheable(request, response) {
  return (
    request.method === 'GET' &&
    new URL(request.url).origin === self.location.origin &&
    response.status === 200 &&
    response.type !== 'opaque'
  );
}

/// The request to put on the wire — revalidated, not taken from the HTTP
/// cache.
///
/// Without this the worker would store whatever the HTTP cache handed it,
/// and an offline user could end up pinned to a build that was already
/// replaced. Measured against a local deploy: a plain fetch still returned
/// the previous file (GitHub Pages sends `max-age=600`, so up to ten
/// minutes), `cache: 'no-cache'` returned the new one. It is a conditional
/// request, so the usual answer is a 304 and no bytes move.
function revalidating(request) {
  // Range requests must keep their header, or a 206 turns into a full 200.
  if (
    request.method !== 'GET' ||
    request.headers.has('range') ||
    new URL(request.url).origin !== self.location.origin
  ) {
    return request;
  }
  return new Request(request.url, {
    cache: 'no-cache',
    credentials: 'same-origin',
  });
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  // Range requests must pass through untouched — rewriting a 206 response
  // breaks media loading.
  if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') {
    return;
  }

  event.respondWith(
    (async () => {
      // Network first, cache as fallback: the deployed app must never be
      // pinned to a stale build just because the user visited before. The
      // cache exists for the case the network genuinely is not there.
      try {
        const response = await fetch(revalidating(request));
        if (isCacheable(request, response)) {
          const copy = response.clone();
          event.waitUntil(
            caches
              .open(CACHE)
              .then((cache) => cache.put(request, harden(copy)))
              // A full disk or a private-mode quota must not break the page.
              .catch((error) => console.warn('coi-sw: cache put failed', error)),
          );
        }
        return harden(response);
      } catch (error) {
        const cached = await caches.match(request);
        if (cached) return cached; // already carries the isolation headers
        // A navigation with nothing cached for this exact URL still starts
        // if the app shell is there — the base document is what boots
        // Flutter, and its query string is irrelevant.
        if (request.mode === 'navigate') {
          const shell = await caches.match(self.registration.scope);
          if (shell) return shell;
        }
        console.error('coi-sw: offline and nothing cached', request.url, error);
        throw error;
      }
    })(),
  );
});
