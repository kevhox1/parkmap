const CACHE_VERSION = 'wepark-v1';
const STATIC_CACHE = CACHE_VERSION + '-static';
const TILE_CACHE = CACHE_VERSION + '-tiles';

const STATIC_ASSETS = [
  'index.html',
  'manifest.json',
  'icon-192.png',
  'icon-512.png',
  'osm_data.json',
  'osm_geo.js',
  'osm_streets.json',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
  'https://cdnjs.cloudflare.com/ajax/libs/proj4js/2.9.0/proj4.js'
];

// Install: cache static assets
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then(cache => {
      console.log('[SW] Installing, caching static assets...');
      return cache.addAll(STATIC_ASSETS);
    }).then(() => self.skipWaiting())
  );
});

// Activate: clean old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => {
      console.log('[SW] Activating, cleaning old caches:', keys);
      return Promise.all(
        keys
          .filter(k => !k.startsWith('wepark'))
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

  // Cache-first for tile files (tile_*.json) — lazy load on demand
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
          console.log('[SW] Tile fetch failed, offline:', pathname);
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

  // Cache-first for all other assets (OSM data, static files, CDN libs)
  event.respondWith(
    caches.match(event.request).then(cached => {
      if (cached) return cached;
      return fetch(event.request).then(response => {
        if (response.ok && (request.method === 'GET' || request.method === undefined)) {
          const clone = response.clone();
          caches.open(STATIC_CACHE).then(cache => cache.put(event.request, clone));
        }
        return response;
      }).catch(err => {
        console.log('[SW] Fetch failed:', pathname, err);
        return new Response('Offline - resource not cached', { status: 503 });
      });
    })
  );
});
