const CACHE_VERSION = 'wepark-v4';
const STATIC_CACHE = CACHE_VERSION + '-static';
const TILE_CACHE = CACHE_VERSION + '-tiles';

const STATIC_ASSETS = [
  'index.html',
  'manifest.json',
  'icon-192.png',
  'icon-512.png',
  'tiles/index.json',
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

// Activate: clean old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => {
      return Promise.all(
        keys
          .filter(k => k.startsWith('wepark') && !k.startsWith(CACHE_VERSION))
          .map(k => {
            console.log('[SW] Deleting old cache:', k);
            return caches.delete(k);
          })
      );
    }).then(() => {
      console.log('[SW] Activation complete');
      return self.clients.claim();
    })
  );
});

// Fetch strategies
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  const pathname = url.pathname;

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
