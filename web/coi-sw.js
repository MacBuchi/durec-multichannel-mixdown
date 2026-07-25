// Cross-origin-isolation service worker.
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
// Registered from index.html, which reloads once so this worker controls
// the page.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) =>
  event.waitUntil(self.clients.claim()),
);

self.addEventListener('fetch', (event) => {
  const request = event.request;
  // Range requests must pass through untouched — rewriting a 206 response
  // breaks media loading.
  if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') {
    return;
  }

  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response.status === 0) return response; // opaque, leave alone
        const headers = new Headers(response.headers);
        headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
        headers.set('Cross-Origin-Opener-Policy', 'same-origin');
        headers.set('Cross-Origin-Resource-Policy', 'same-origin');
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers,
        });
      })
      .catch((error) => {
        console.error('coi-sw: fetch failed', error);
        throw error;
      }),
  );
});
