/* service worker: เก็บตัวหน้าแอปไว้ในเครื่อง เปิดได้แม้ไม่มีสัญญาณ ; ไม่แคช API */
const V = 'v2';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;   // API / ฟอนต์ภายนอก ผ่านปกติ
  /* network-first : ได้เวอร์ชันใหม่เสมอเมื่อออนไลน์ ; ออฟไลน์ใช้ที่แคชไว้ */
  e.respondWith(fetch(e.request).then(r => { const cp = r.clone(); caches.open(V).then(c => c.put(e.request, cp)); return r; })
    .catch(() => caches.match(e.request).then(m => m || caches.match('index.html'))));
});
