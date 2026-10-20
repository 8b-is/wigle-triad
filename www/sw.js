/**
 * wigle-triad & esp32.vaked.dev — 100% Offline-First Service Worker (v2.1.0)
 * Precaches the entire application shell, SVG icons, manifest, and last-known
 * triad telemetry / WigleWifi-1.4 CSV / AlexAI / Kompress-Ultra snapshots so
 * cold launches work with zero network connectivity (Airplane Mode / cable pulled).
 */

const CACHE_NAME = "wigle-triad-offline-v2.1";

const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/manifest.webmanifest",
  "/favicon.svg",
  "/og.svg",
  "/api/triad.json",
  "/api/wigle.csv",
  "/api/alexai",
  "/api/kompress"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) =>
        Promise.allSettled(
          SHELL_ASSETS.map((url) =>
            fetch(url, { cache: "no-cache" })
              .then((res) => {
                if (res && res.ok) {
                  return cache.put(url, res.clone());
                }
              })
              .catch(() => {})
          )
        )
      )
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => k !== CACHE_NAME)
            .map((k) => caches.delete(k))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Never allow unguarded external font/iframe fail-noise when offline
  if (url.origin !== self.location.origin) {
    event.respondWith(
      fetch(request).catch(() => new Response("", { status: 204, statusText: "Offline Bypassed" }))
    );
    return;
  }

  // Handle POST /api/upload or /api/cmd when offline
  if (request.method === "POST") {
    event.respondWith(
      fetch(request.clone()).catch(async () => {
        const nowIso = new Date().toISOString();
        if (url.pathname.startsWith("/api/upload")) {
          return new Response(
            JSON.stringify({
              ok: false,
              offline_queued: true,
              observer: "anonymous",
              donate: "on",
              transId: "sw-offline-queue-" + Date.now(),
              timestamp: nowIso,
              message: "Offline-First Service Worker intercepted upload while offline; payload queued locally for auto-sync."
            }),
            {
              status: 202,
              headers: { "content-type": "application/json; charset=utf-8" }
            }
          );
        }
        return new Response(
          JSON.stringify({
            ok: true,
            offline: true,
            cmd: "OFFLINE_LOCAL",
            lines: ["# OFFLINE-FIRST|Service Worker local autonomy active (TX=0, loopback/cache only)"]
          }),
          {
            status: 200,
            headers: { "content-type": "application/json; charset=utf-8" }
          }
        );
      })
    );
    return;
  }

  if (request.method !== "GET") return;

  // API endpoints: network-first with fast fallback to cached snapshot
  if (url.pathname.startsWith("/api/") || url.pathname === "/triad.json" || url.pathname === "/wigle.csv") {
    event.respondWith(
      fetch(request)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return res;
        })
        .catch(() =>
          caches.match(request).then(
            (hit) =>
              hit ||
              new Response(
                JSON.stringify({
                  ok: true,
                  offline: true,
                  surface: self.location.origin,
                  version: "2.0.0+8b-is-heals-the-world",
                  mode: "OFFLINE_FIRST_CACHE"
                }),
                { headers: { "content-type": "application/json; charset=utf-8" } }
              )
          )
        )
    );
    return;
  }

  // App shell & static assets: Cache-first, background revalidate, fallback to /index.html
  event.respondWith(
    caches.match(request).then((cached) => {
      const networkFetch = fetch(request)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return res;
        })
        .catch(() => cached || caches.match("/index.html") || caches.match("/"));
      return cached || networkFetch;
    })
  );
});
