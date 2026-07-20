// 보드게임 Hub — 서비스워커 (PWA 설치 + 앱 셸 오프라인 대비)
// 캐시 버전만 올리면 갱신됩니다.
const CACHE = 'bgh-v11';
const SHELL = [
  './',
  './index.html',
  './styles.css',
  './app.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-192-maskable.png',
  './icons/icon-512-maskable.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  // 쓰기(RPC 등)는 항상 네트워크
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // 크로스오리진(Supabase API / 폰트 / supabase-js CDN)은 가로채지 않음 → 항상 네트워크
  if (url.origin !== self.location.origin) return;
  // 앱 셸: 네트워크 우선 + 캐시 폴백 (업데이트 즉시 반영, 오프라인 시 캐시 사용)
  e.respondWith(
    fetch(req)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      })
      .catch(() => caches.match(req).then((r) => r || caches.match('./index.html')))
  );
});
