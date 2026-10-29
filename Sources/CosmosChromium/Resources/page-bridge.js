// Runs in the page's own world, before the page's scripts, for what Chromium headless has no window for.
// Permissions: Chromium turns every request down itself, having nowhere to ask. This asks Cosmos first (through Cosmos's
// isolated world, see engine-helper.js); Cosmos sets Chromium's permission for the site, and then the page's own call goes
// ahead, so what the page gets is still Chromium's decision. A page that gets around this only meets Chromium's refusal.
// Picture in Picture: Cosmos shows the video in a window of its own; the page sees the element and events Chrome gives.
// Notifications: Chromium "shows" them where nobody sees; Cosmos posts them to macOS, and clicks come back as their events.
(function () {
  'use strict';
  if (window.__cosmosPageBridge) return;
  Object.defineProperty(window, '__cosmosPageBridge', { value: true });

  const NativeNotification = window.Notification;
  let next = 1;
  const waiting = new Map();
  window.addEventListener('message', e => {
    const d = e.data;
    // Only Cosmos's answer, which comes from this window (engine-helper.js); another frame could post the same shape.
    if (e.source !== window || !d || typeof d.__cosmosAnswer !== 'number') return;
    const done = waiting.get(d.__cosmosAnswer);
    if (done) { waiting.delete(d.__cosmosAnswer); done(d.value); }
  });
  const ask = (kind, what = 'permission') => new Promise(resolve => {
    const id = next++;
    waiting.set(id, resolve);
    window.postMessage({ __cosmosAsk: what, id, kind }, '*');
  });

  // Defined as methods, so they keep the name and shape of the ones they stand in for.
  const replace = (owner, name, make) => {
    const original = owner && owner[name];
    if (typeof original !== 'function') return;
    const replacement = make(original);
    Object.defineProperty(owner, name, { value: { [name](...args) { return replacement.apply(this, args); } }[name], writable: true, configurable: true });
  };

  if (window.MediaDevices) {
    replace(MediaDevices.prototype, 'getUserMedia', original => function (constraints) {
      const c = constraints || {};
      const kind = c.video && c.audio ? 'cameraAndMicrophone' : c.video ? 'camera' : c.audio ? 'microphone' : null;
      if (!kind) return original.call(this, constraints);
      return ask(kind).then(() => original.call(this, constraints));
    });
  }

  if (window.Geolocation) {
    replace(Geolocation.prototype, 'getCurrentPosition', original => function (...args) {
      ask('location').then(() => original.apply(this, args));
    });
    // A watch has its id at once; the real one comes once Cosmos has answered.
    const watches = new Map();
    let nextWatch = 1;
    const clear = Geolocation.prototype.clearWatch;
    replace(Geolocation.prototype, 'watchPosition', original => function (...args) {
      const id = nextWatch++;
      watches.set(id, null);
      ask('location').then(() => { if (watches.has(id)) watches.set(id, original.apply(this, args)); });
      return id;
    });
    replace(Geolocation.prototype, 'clearWatch', () => function (id) {
      const real = watches.get(id);
      watches.delete(id);
      if (real != null) clear.call(this, real);
    });
  }

  if (window.HTMLVideoElement && window.Document) {
    let element = null;
    const pipWindow = v => ({ width: v.videoWidth, height: v.videoHeight, onresize: null, addEventListener() {}, removeEventListener() {} });
    const fire = (v, type) => { const e = new Event(type, { bubbles: true }); e.pictureInPictureWindow = pipWindow(v); v.dispatchEvent(e); };
    // Cosmos's window closed, or the page asked: the video is back in the page.
    const leave = () => {
      if (!element) return;
      const v = element;
      element = null;
      v.removeAttribute('data-cosmos-pip');
      fire(v, 'leavepictureinpicture');
    };
    Object.defineProperty(window, '__cosmosLeavePictureInPicture', { value: leave });
    replace(HTMLVideoElement.prototype, 'requestPictureInPicture', () => function () {
      const v = this;
      if (v.readyState === 0) return Promise.reject(new DOMException('Metadata for the video element are not loaded yet.', 'InvalidStateError'));
      if (v.disablePictureInPicture) return Promise.reject(new DOMException('Picture in Picture is disabled for this video.', 'InvalidStateError'));
      if (element === v) return Promise.resolve(pipWindow(v));
      if (element) leave();
      v.setAttribute('data-cosmos-pip', '');
      return ask('video', 'pictureInPicture').then(shown => {
        if (!shown) { v.removeAttribute('data-cosmos-pip'); throw new DOMException('Picture in Picture is not available.', 'NotAllowedError'); }
        element = v;
        fire(v, 'enterpictureinpicture');
        return pipWindow(v);
      });
    });
    Object.defineProperty(Document.prototype, 'pictureInPictureElement', { get() { return this === document ? element : null; }, configurable: true });
    replace(Document.prototype, 'exitPictureInPicture', () => function () {
      if (!element) return Promise.reject(new DOMException('There is no Picture-in-Picture element in this document.', 'InvalidStateError'));
      return ask('video', 'leavePictureInPicture').then(leave);
    });
  }

  if (NativeNotification) {
    replace(NativeNotification, 'requestPermission', original => function (callback) {
      const answer = ask('notifications').then(() => original.call(NativeNotification));
      if (typeof callback === 'function') answer.then(callback);
      return answer;
    });

    const tell = (what, note) => window.postMessage({ __cosmosTell: what, note }, '*');
    const notes = new Map();
    const idOf = new WeakMap();
    let nextNote = 1;
    // A tag names the notification, so a new one with it replaces the old, as in Chrome.
    const name = (options, prefix) => (options && options.tag) ? 'tag:' + options.tag : prefix + nextNote++;
    const describe = (id, title, options) => ({ id, title: String(title), body: options && options.body ? String(options.body) : '', origin: location.hostname });
    // The real Notification makes the object (and checks the permission); statics read the real one.
    const proxy = new Proxy(NativeNotification, {
      construct(target, args) {
        const n = Reflect.construct(target, args);
        if (NativeNotification.permission === 'granted') {
          const id = name(args[1], 'n');
          notes.set(id, n);
          idOf.set(n, id);
          tell('notification', describe(id, args[0], args[1]));
        }
        return n;
      },
      get(target, property) { return Reflect.get(target, property, target); }
    });
    Object.defineProperty(window, 'Notification', { value: proxy, writable: true, configurable: true });
    replace(NativeNotification.prototype, 'close', original => function () {
      const id = idOf.get(this);
      if (id && notes.get(id) === this) { notes.delete(id); tell('notificationClose', { id }); }
      return original.call(this);
    });
    if (window.ServiceWorkerRegistration) {
      replace(ServiceWorkerRegistration.prototype, 'showNotification', original => function (title, options) {
        return original.call(this, title, options).then(result => {
          if (NativeNotification.permission === 'granted') tell('notification', describe(name(options, 'w'), title, options));
          return result;
        });
      });
    }
    // The user clicked or closed one in macOS.
    Object.defineProperty(window, '__cosmosNotificationAction', { value: (id, action) => {
      const n = notes.get(id);
      if (!n) return;
      if (action === 'closed') notes.delete(id);
      n.dispatchEvent(new Event(action === 'closed' ? 'close' : 'click'));
    } });
  }
})();
