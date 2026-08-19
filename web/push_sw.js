self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = {};
  }
  // Service/presence/typing pushes carry no body — silently drop them.
  if (!payload.body) return;
  const title = payload.title || 'Rlink';
  const tag = payload.tag || 'rlink-message';
  const kind = (payload.data && payload.data.kind) || 'message';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.body,
      tag,
      renotify: true,
      // Account-transfer requests are consequential and time-sensitive
      // (the old device has to actually see and act on this) — don't let
      // it auto-dismiss like a regular message notification can.
      requireInteraction: kind === 'account_transfer',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      data: payload.data || {},
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = self.registration.scope || '/';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) {
          return client.focus();
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
      return null;
    }),
  );
});
