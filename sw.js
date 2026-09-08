const CACHE='bgmi-yodha-v5-blue';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['./','./index.html','./manifest.json','./payment-qr.jpg','./erangel-card.jpg']))));
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request))));
self.addEventListener('push',e=>{let d={title:'BGMI YODHA',body:'New tournament update available!',url:'./index.html#notifications'};try{if(e.data)d=Object.assign(d,e.data.json())}catch(_){}e.waitUntil(self.registration.showNotification(d.title,{body:d.body,icon:'./erangel-card.jpg',badge:'./erangel-card.jpg',data:{url:d.url}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{for(const c of cs){if('focus' in c){c.navigate((e.notification.data&&e.notification.data.url)||'./index.html#notifications');return c.focus()}}return clients.openWindow((e.notification.data&&e.notification.data.url)||'./index.html#notifications')}))});
