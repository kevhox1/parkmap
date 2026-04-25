const CACHE_VERSION = 'wepark-v19';
const STATIC_CACHE = CACHE_VERSION + '-static';
const TILE_CACHE = CACHE_VERSION + '-tiles';

// Note: tracker-config.js intentionally NOT precached — it carries auth keys
// that may rotate and we want a fresh fetch every page load. The fetch handler
// below is network-first for everything that isn't a tile, so it stays fresh.
const STATIC_ASSETS = [
  'index.html',
  'manifest.json',
  'icon-192.png',
  'icon-512.png',
  'tiles/index.json',
  'osm_oneway.json',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
];

// Install: cache static assets (don't let one failure block install)
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then(cache => {
      console.log('[SW] Installing, caching static assets...');
      // Use individual puts so one 404 doesn't block the whole install
      return Promise.allSettled(
        STATIC_ASSETS.map(url =>
          fetch(url).then(resp => {
            if (resp.ok) return cache.put(url, resp);
          }).catch(() => console.warn('[SW] Failed to cache:', url))
        )
      );
    }).then(() => self.skipWaiting())
  );
});

// Activate: clean old caches AND broadcast a reload signal to all clients so
// they pick up the new code immediately instead of running stale JS until the
// user manually refreshes. Combined with skipWaiting() in install + clients.claim()
// here, this means: deploy v(N+1), users running v(N) auto-update + reload on
// next page load. No more "clear cache" for users.
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter(k => k.startsWith('wepark') && !k.startsWith(CACHE_VERSION))
        .map(k => {
          console.log('[SW] Deleting old cache:', k);
          return caches.delete(k);
        })
    );
    await self.clients.claim();
    const clients = await self.clients.matchAll({ type: 'window' });
    for (const client of clients) {
      client.postMessage({ type: 'WEPARK_SW_UPDATED', version: CACHE_VERSION });
    }
    console.log('[SW] Activation complete:', CACHE_VERSION);
  })());
});

// Allow the page to ping us for the active version
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'WEPARK_GET_VERSION') {
    event.ports[0]?.postMessage({ version: CACHE_VERSION });
  }
});

function isSupabaseLiveRequest(url) {
  return url.hostname.endsWith('.supabase.co')
    || url.pathname.startsWith('/rest/v1/')
    || url.pathname.startsWith('/auth/v1/')
    || url.pathname.startsWith('/realtime/v1/')
    || url.pathname.startsWith('/functions/v1/')
    || url.pathname.startsWith('/storage/v1/');
}

// Fetch strategies
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  const pathname = url.pathname;

  // Never cache live backend traffic, especially tracker reads/auth/realtime.
  if (isSupabaseLiveRequest(url)) {
    event.respondWith(fetch(event.request));
    return;
  }

  // Network-first for index.html (always pick up latest)
  if (pathname.endsWith('/') || pathname.endsWith('/index.html') || pathname.endsWith('index.html')) {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(STATIC_CACHE).then(cache => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  // Network-first for tile index (critical, should always be fresh)
  if (pathname.endsWith('/tiles/index.json')) {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(STATIC_CACHE).then(cache => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  // Cache-first for tile data files (tile_*.json) — lazy load on demand
  if (pathname.match(/\/tile_\d+_\d+\.json$/)) {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(TILE_CACHE).then(cache => cache.put(event.request, clone));
          }
          return response;
        }).catch(() => {
          return new Response(JSON.stringify([]), {
            status: 503,
            statusText: 'Service Unavailable (offline)',
            headers: { 'Content-Type': 'application/json' }
          });
        });
      })
    );
    return;
  }

  // Network-first for everything else
  event.respondWith(
    fetch(event.request)
      .then(response => {
        if (response.ok && event.request.method === 'GET') {
          const clone = response.clone();
          caches.open(STATIC_CACHE).then(cache => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
