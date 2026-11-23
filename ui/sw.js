const CACHE_NAME = "freeimage-local-pwa-v3";
const SHELL_ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon.svg",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Only handle same-origin GET requests in the service worker; cross-origin local engine calls go directly to network
  if (url.origin !== self.location.origin) return;

  if (url.pathname.endsWith("/api/history") && request.method === "GET") {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((c) => c.put(request, copy));
          return res;
        })
        .catch(async () => {
          const cached = await caches.match(request);
          return cached || new Response("[]", { headers: { "content-type": "application/json" } });
        })
    );
    return;
  }

  if (url.pathname.includes("/api/")) {
    event.respondWith(
      fetch(request).catch(() => {
        const status = url.pathname.endsWith("/api/generate") ? 503 : 200;
        return new Response(
          JSON.stringify({
            offline: true,
            active: false,
            error: "Local engine is offline. Run start-app.bat or use Demo Simulator Mode."
          }),
          { status, headers: { "content-type": "application/json" } }
        );
      })
    );
    return;
  }

  if (url.pathname.includes("/outputs/")) {
    event.respondWith(
      caches.match(request).then((cached) => {
        const net = fetch(request)
          .then((res) => {
            if (res.ok) {
              const copy = res.clone();
              caches.open(CACHE_NAME).then((c) => c.put(request, copy));
            }
            return res;
          })
          .catch(() => cached);
        return cached || net;
      })
    );
    return;
  }

  if (request.method === "GET") {
    event.respondWith(
      fetch(request)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((c) => c.put(request, copy));
          }
          return res;
        })
        .catch(async () => {
          const cached = await caches.match(request);
          if (cached) return cached;
          if (request.mode === "navigate") {
            return (await caches.match("./index.html")) || (await caches.match("./"));
          }
          throw new Error("Offline");
        })
    );
  }
});
