// Eufynized for Home Assistant: the Security Camera page. Everything is relative to the ingress root, and all
// camera traffic goes through the add-on's bridge (direct HomeBase P2P) — live video via its bundled go2rtc.

const $ = (sel, root = document) => root.querySelector(sel);
const h = (tag, attrs = {}, ...children) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'html') el.innerHTML = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
const icon = (paths) => { const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); s.setAttribute('viewBox', '0 0 24 24'); s.innerHTML = paths; return s; };
const ICONS = {
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  back: '<path d="M15 18l-6-6 6-6"/>',
  close: '<path d="M18 6L6 18M6 6l12 12"/>',
  sound: '<path d="M11 5L6 9H2v6h4l5 4V5z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M19 5a10 10 0 0 1 0 14"/>',
  mute: '<path d="M11 5L6 9H2v6h4l5 4V5z"/><path d="M23 9l-6 6M17 9l6 6"/>',
  mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10v1a7 7 0 0 0 14 0v-1M12 18v4"/>',
  up: '<path d="M6 15l6-6 6 6"/>', down: '<path d="M6 9l6 6 6-6"/>', left: '<path d="M15 6l-6 6 6 6"/>', right: '<path d="M9 6l6 6-6 6"/>',
  arrange: '<path d="M5 9l-3 3 3 3M9 5l3-3 3 3M15 19l-3 3-3-3M19 9l3 3-3 3M2 12h20M12 2v20"/>',
  expand: '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>',
  calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
};

async function api(path, options = {}) {
  const init = { ...options };
  // Never hang: a request that's stuck (a dropped connection, the bridge restarting) fails after a while instead.
  // Settings writes and event lists can take a while on the HomeBase's side.
  if (!init.signal && typeof AbortSignal.timeout === 'function') init.signal = AbortSignal.timeout(options.timeout ?? 60000);
  if (options.json !== undefined) {
    init.method = init.method || 'POST';
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(options.json);
  }
  const res = await fetch('api/' + path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok && res.status !== 422 && res.status !== 202) throw new Error(data.error || data.message || `HTTP ${res.status}`);
  return data;
}

const store = {
  get(k, d) { try { const v = localStorage.getItem('eufynized.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('eufynized.' + k, JSON.stringify(v)); } catch {} },
};

// In a dashboard card (`?embed=1`) the page opens on the card's tab and leaves out the logo.
const params = new URLSearchParams(location.search);
const embedded = params.get('embed') === '1';
if (embedded) document.documentElement.classList.add('embed');

const state = {
  cameras: [],
  prefs: { order: [], layout: 'auto', thumbnailSize: 300 },
  tab: params.get('view') || store.get('tab', 'cameras'),
  snapshots: new Map(),   // channel -> object URL of the freshest picture
  liveOpen: null,
};

const isTouch = matchMedia('(pointer: coarse)').matches;
const fmtTime = (ms) => new Date(ms).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
const fmtAgo = (ms) => {
  const s = (Date.now() - ms) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return new Date(ms).toLocaleDateString([], { month: 'short', day: 'numeric' });
};

/** Cameras in the user's order (shared by every browser); new cameras follow in channel order. */
function ordered() {
  const rank = new Map(state.prefs.order.map((ch, i) => [ch, i]));
  return [...state.cameras].sort((a, b) => {
    const x = rank.get(a.channel), y = rank.get(b.channel);
    if (x != null && y != null) return x - y;
    if (x != null) return -1;
    if (y != null) return 1;
    return a.channel - b.channel;
  });
}

function savePrefs(update) {
  Object.assign(state.prefs, update);
  api('prefs', { method: 'PUT', json: update }).catch(() => {});
}

function moveCamera(channel, target) {
  const order = ordered().map(c => c.channel);
  const from = order.indexOf(channel), to = order.indexOf(target);
  if (from < 0 || to < 0 || from === to) return;
  order.splice(from, 1);
  order.splice(to, 0, channel);
  savePrefs({ order });
}

function swapCameras(channel, target) {
  const order = ordered().map(c => c.channel);
  const a = order.indexOf(channel), b = order.indexOf(target);
  if (a < 0 || b < 0 || a === b) return;
  [order[a], order[b]] = [order[b], order[a]];
  savePrefs({ order });
}

// MARK: - Live player

/**
 * `<eufy-live>`: plays a camera from the bridge's live stream (`api/live/<channel>.mp4`) with Media Source
 * Extensions — ManagedMediaSource on iPhone. The stream is framed `[type][length][payload]`: 1 a MIME type,
 * 2 an init segment, 3 a fragment (one frame). Cameras change resolution as they go (Auto quality ramps 720p →
 * 1080p → 2K/4K, and steps down when the network is busy); each change arrives as a new init segment, which the
 * player switches to without a restart — the way the Mac app gives its decoder a new format.
 *
 * Only plays while on screen and while the page is visible, so nothing streams when nobody is looking.
 */
class EufyLive extends HTMLElement {
  constructor() {
    super();
    const v = this.video = document.createElement('video');
    v.playsInline = true; v.muted = true; v.autoplay = true; v.disableRemotePlayback = true;
    v.setAttribute('playsinline', '');
    v.style.cssText = 'display:block;width:100%;height:100%;object-fit:contain;background:#000';
    v.addEventListener('playing', () => this.emit('state', 'playing'));
    v.addEventListener('waiting', () => this.emit('state', 'waiting'));
    v.addEventListener('volumechange', () => this.emit('mutechange'));
    this.onScreen = true;
    this.onVisibility = () => this.update();
  }

  emit(type, detail) { this.dispatchEvent(new CustomEvent(type, { detail })); }

  connectedCallback() {
    if (!this.video.isConnected) this.append(this.video);
    document.addEventListener('visibilitychange', this.onVisibility);
    this.observer = new IntersectionObserver(([entry]) => { this.onScreen = entry.isIntersecting; this.update(); });
    this.observer.observe(this);
    this.update();
  }

  disconnectedCallback() {
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.observer?.disconnect();
    clearTimeout(this.idleTimer);
    this.stop();
  }

  /** Starts when wanted; stops a few seconds after the tile scrolls away or the page goes to the background. */
  update() {
    const wanted = this.isConnected && !document.hidden && this.onScreen;
    clearTimeout(this.idleTimer);
    if (wanted) this.start();
    else this.idleTimer = setTimeout(() => this.stop(), 4000);
  }

  start() {
    if (this.session || !this.src) return;
    const s = this.session = { abort: new AbortController(), queue: [], sb: null, mime: null, lastData: Date.now(), appended: false };
    this.run(s).catch((err) => this.fail(s, err));
  }

  stop() {
    const s = this.session;
    if (!s) return;
    this.session = null;
    s.abort.abort();
    clearInterval(s.timer);
    try { if (s.ms?.readyState === 'open') s.ms.endOfStream(); } catch {}
    this.video.removeAttribute('src');
    this.video.srcObject = null;
  }

  /** Something went wrong: keep the last frame on screen and reconnect shortly. */
  fail(s, err) {
    if (this.session !== s) return;
    const v = this.video;
    try {
      if (v.videoWidth) {
        const c = document.createElement('canvas');
        c.width = v.videoWidth; c.height = v.videoHeight;
        c.getContext('2d').drawImage(v, 0, 0);
        v.poster = c.toDataURL('image/jpeg', 0.7);
      }
    } catch {}
    this.stop();
    if (err?.name !== 'AbortError') {
      this.lastError = `${err?.message || err}${v.error ? ` (media ${v.error.code} ${v.error.message || ''})` : ''}`;
      this.errors = (this.errors || 0) + 1;
      console.warn('[eufy-live]', this.dataset.ch, this.lastError);
    }
    if (!(window.ManagedMediaSource || window.MediaSource)) { this.emit('state', 'error:This browser can\'t play live video'); return; }
    this.emit('state', 'waiting');
    // A camera the HomeBase reports offline is refused up front: say so, and look again less often.
    const offline = err?.message === 'could not connect';
    if (offline) {
      api('cameras').then((list) => {
        const cam = list.find((c) => String(c.channel) === this.dataset.ch);
        if (cam?.availability && cam.availability !== 'online') this.emit('state', `offline:${cam.availability}`);
      }).catch(() => {});
    }
    setTimeout(() => { if (!this.session) this.update(); }, offline ? 20000 : 1500);
  }

  async run(s) {
    const MS = window.ManagedMediaSource || window.MediaSource;
    if (!MS) throw new Error('no Media Source support');
    s.ms = new MS();
    if (window.ManagedMediaSource) this.video.srcObject = s.ms;
    else this.video.src = URL.createObjectURL(s.ms);
    await new Promise((resolve) => s.ms.addEventListener('sourceopen', resolve, { once: true }));
    // A WebSocket rather than a streamed fetch: browsers allow only six streaming HTTP/1.1 connections per
    // server, and Multi-View needs one per camera.
    const url = new URL(this.src, location.href);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = s.ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    s.abort.signal.addEventListener('abort', () => ws.close());
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error('could not connect'));
    });
    ws.onerror = null;
    ws.onclose = () => this.fail(s, new Error('stream closed'));
    s.timer = setInterval(() => {
      // The first picture can take a while (the camera wakes, then sends its next keyframe); after that, 12 s
      // without data means the stream is stuck.
      const limit = s.appended ? 12000 : 30000;
      if (Date.now() - s.lastData > limit) this.fail(s, new Error(`no data for ${limit / 1000} s`));
      else this.keepLive(s);
    }, 250);
    let buf = new Uint8Array(0);
    ws.onmessage = (message) => {
      if (this.session !== s) return;
      s.lastData = Date.now();
      const value = new Uint8Array(message.data);
      const joined = new Uint8Array(buf.length + value.length);
      joined.set(buf); joined.set(value, buf.length);
      buf = joined;
      let offset = 0;
      while (buf.length - offset >= 5) {
        const len = ((buf[offset + 1] << 24) >>> 0) + (buf[offset + 2] << 16) + (buf[offset + 3] << 8) + buf[offset + 4];
        if (buf.length - offset - 5 < len) break;
        const type = buf[offset], payload = buf.subarray(offset + 5, offset + 5 + len);
        offset += 5 + len;
        if (type === 1) s.queue.push({ mime: new TextDecoder().decode(payload) });
        else if (s.sb || s.queue.some((op) => op.mime)) s.queue.push({ data: payload.slice() });
      }
      buf = buf.subarray(offset);
      if (s.queue.length > 400) { this.fail(s, new Error('falling behind')); return; }
      this.pump(s);
    };
  }

  /** Feeds the queue into the SourceBuffer, one append at a time. */
  pump(s) {
    if (this.session !== s) return;
    if (!s.sb) {
      while (s.queue.length && !s.queue[0].mime) s.queue.shift();
      if (!s.queue.length) return;
      const { mime } = s.queue.shift();
      const MS = window.ManagedMediaSource || window.MediaSource;
      if (!MS.isTypeSupported(mime)) { this.emit('state', `error:This device can't play ${mime.includes('hvc1') ? 'H.265' : 'this'} video`); this.stop(); return; }
      this.mime = mime;
      s.sb = s.ms.addSourceBuffer(mime);
      s.mime = mime;
      s.sb.mode = 'segments';
      s.sb.addEventListener('updateend', () => this.pump(s));
      s.sb.addEventListener('error', () => this.fail(s, new Error('SourceBuffer error')));
    }
    while (!s.sb.updating && s.queue.length) {
      const op = s.queue.shift();
      if (op.mime) {
        if (op.mime !== s.mime && s.sb.changeType) s.sb.changeType(op.mime);
        s.mime = this.mime = op.mime;
        continue;
      }
      try {
        s.sb.appendBuffer(op.data);
        s.appended = true;   // playback starts once there's a little buffer (keepLive)
      } catch (err) {
        if (err.name === 'QuotaExceededError') { s.queue.unshift(op); this.trim(s, 2); return; }
        this.fail(s, err);
      }
      return;   // the next append waits for updateend
    }
  }

  /**
   * A jitter buffer, like the Mac app's: plays about a second behind the newest frame so a late packet doesn't
   * starve the decoder. Nudges the speed to hold that, jumps only when far behind, and drops old buffer.
   */
  keepLive(s) {
    const v = this.video, b = v.buffered;
    if (!b.length || !s.sb) return;
    const end = b.end(b.length - 1), lastStart = b.start(b.length - 1);
    if (v.currentTime < lastStart) v.currentTime = Math.max(lastStart, end - EufyLive.TARGET);   // stuck before a gap
    // Past the newest frame (it happens after a burst of dropped frames): back to the live edge, or the picture
    // would hold until the stream caught up with the playhead.
    if (v.currentTime > end + 0.25) v.currentTime = Math.max(lastStart, end - 0.3);
    const lag = end - v.currentTime;
    if (lag > 3) v.currentTime = end - EufyLive.TARGET;
    const rate = lag > 1.8 ? 1.1 : lag > 1.3 ? 1.04 : lag < 0.35 ? 0.85 : lag < 0.7 ? 0.95 : 1;
    if (v.playbackRate !== rate) v.playbackRate = rate;
    if (v.paused && v.readyState >= 2 && lag >= 0.6) {
      v.play().catch(() => { if (!v.muted) { v.muted = true; v.play().catch(() => {}); } });
    }
    this.lag = lag;
    this.trim(s, 15);
  }

  trim(s, keepSeconds) {
    const v = this.video, b = v.buffered;
    if (!b.length || s.sb.updating) return;
    const cut = v.currentTime - keepSeconds;
    if (b.start(0) < cut) { try { s.sb.remove(0, cut); } catch {} }
  }
}
/** Seconds behind the newest frame that playback aims for. */
EufyLive.TARGET = 1.0;
customElements.define('eufy-live', EufyLive);

// Diagnostics (tap the logo five times): each player shows its resolution, codec, buffer and last error, so a
// phone screenshot says what went wrong.
let diagnostics = store.get('diagnostics', false);
function drawDiagnostics() {
  for (const el of document.querySelectorAll('eufy-live')) {
    let box = el.querySelector('.diag');
    if (!diagnostics) { box?.remove(); continue; }
    if (!box) { box = h('div', { class: 'diag' }); el.append(box); }
    const v = el.video, q = v.getVideoPlaybackQuality?.();
    const codec = (el.mime || '').replace(/^video\/mp4; codecs="|"$/g, '');
    const support = el.mime ? ((window.ManagedMediaSource || window.MediaSource)?.isTypeSupported(el.mime) ? 'ok' : 'NO') : '-';
    box.textContent = `${window.ManagedMediaSource ? 'MMS' : 'MSE'} ${v.videoWidth}x${v.videoHeight} ${codec} [${support}]\n` +
      `rs${v.readyState} lag ${el.lag?.toFixed?.(2) ?? '-'} x${v.playbackRate} frames ${q?.totalVideoFrames ?? '-'}/${q?.droppedVideoFrames ?? '-'} drop` +
      `${el.errors ? `\nerr×${el.errors}: ${el.lastError}` : ''}`;
  }
}
setInterval(drawDiagnostics, 1000);
let logoTaps = [];
document.querySelector('.brand')?.addEventListener('click', () => {
  logoTaps = [...logoTaps.filter((t) => Date.now() - t < 3000), Date.now()];
  if (logoTaps.length >= 5) {
    logoTaps = [];
    diagnostics = !diagnostics;
    store.set('diagnostics', diagnostics);
    toastText(diagnostics ? 'Diagnostics on' : 'Diagnostics off');
    drawDiagnostics();
  }
});

function makeVideo(channel, { audio = false } = {}) {
  const el = document.createElement('eufy-live');
  el.dataset.ch = channel;
  el.src = `api/live/${channel}.mp4${audio ? '?audio=1' : ''}`;
  return el;
}

// MARK: - Tabs

const views = {
  cameras: { render: renderCameras, leave: () => {} },
  multiview: { render: renderMultiView, leave: leaveMultiView },
  events: { render: renderEvents, leave: () => {} },
  alerts: { render: renderAlerts, leave: () => {} },
};

function showTab(tab) {
  if (!views[tab]) tab = 'cameras';
  if (state.tab !== tab) views[state.tab]?.leave();
  state.tab = tab;
  if (!embedded) store.set('tab', tab);
  for (const b of document.querySelectorAll('.tabs button')) b.setAttribute('aria-selected', b.dataset.tab === tab);
  for (const v of document.querySelectorAll('.view')) v.hidden = v.id !== tab;
  $('#tools').replaceChildren();
  $('main').scrollTop = 0;
  views[tab].render();
}

for (const b of document.querySelectorAll('.tabs button')) b.addEventListener('click', () => showTab(b.dataset.tab));

function tool(...els) { $('#tools').append(...els.filter(Boolean)); }
function refreshButton(onClick) {
  return h('button', { class: 'btn icon', title: 'Refresh', 'aria-label': 'Refresh', onclick: onClick }, icon(ICONS.refresh));
}

// MARK: - Drag to arrange (mouse: just drag; touch: in Arrange mode, so normal swipes still scroll)

function enableDrag(container, selector, onDrop, { touchNeedsArrange = true } = {}) {
  container.addEventListener('pointerdown', (e) => {
    const tile = e.target.closest(selector);
    if (!tile || e.target.closest('button') || e.button > 0) return;
    const arranging = container.classList.contains('arranging');
    if (e.pointerType !== 'mouse' && touchNeedsArrange && !arranging) return;
    const start = { x: e.clientX, y: e.clientY };
    let dragging = false, target = null;
    const move = (ev) => {
      if (!dragging) {
        if (Math.hypot(ev.clientX - start.x, ev.clientY - start.y) < 8) return;
        dragging = true;
        tile.classList.add('dragging');
        try { tile.setPointerCapture(e.pointerId); } catch {}
      }
      ev.preventDefault();
      const el = document.elementFromPoint(ev.clientX, ev.clientY)?.closest(selector);
      const next = el && el !== tile && container.contains(el) ? el : null;
      if (next !== target) { target?.classList.remove('drop-target'); target = next; target?.classList.add('drop-target'); }
    };
    const end = () => {
      tile.removeEventListener('pointermove', move);
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', end);
      window.removeEventListener('pointercancel', end);
      if (!dragging) return;
      tile.classList.remove('dragging');
      target?.classList.remove('drop-target');
      // Swallow the click that follows a drag.
      const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
      window.addEventListener('click', swallow, { capture: true, once: true });
      setTimeout(() => window.removeEventListener('click', swallow, { capture: true }), 50);
      if (target) onDrop(Number(tile.dataset.ch), Number(target.dataset.ch));
    };
    window.addEventListener('pointermove', move, { passive: false });
    window.addEventListener('pointerup', end);
    window.addEventListener('pointercancel', end);
  });
}

// MARK: - Cameras tab

let arrangeCameras = false;
const snapshotQueue = { running: 0, items: [] };

function queueSnapshot(channel, fresh) {
  if (snapshotQueue.items.some(i => i.channel === channel)) return;
  snapshotQueue.items.push({ channel, fresh });
  pumpSnapshots();
}

function pumpSnapshots() {
  while (snapshotQueue.running < 2 && snapshotQueue.items.length) {
    const { channel, fresh } = snapshotQueue.items.shift();
    snapshotQueue.running++;
    setTileBusy(channel, true);
    fetch(`api/cameras/${channel}/snapshot.jpg?${fresh ? 'fresh=1' : 'maxAge=300'}`)
      .then(r => r.ok ? r.blob() : Promise.reject(r))
      .then(blob => {
        const old = state.snapshots.get(channel);
        const url = URL.createObjectURL(blob);
        state.snapshots.set(channel, url);
        if (old) setTimeout(() => URL.revokeObjectURL(old), 5000);
        const cam = state.cameras.find(c => c.channel === channel);
        if (cam) { cam.snapshotAt = Date.now(); cam.online = true; delete cam.availability; }
        updateTile(channel);
      })
      .catch(async (r) => {
        const cam = state.cameras.find(c => c.channel === channel);
        if (cam && r && r.json) { const d = await r.json().catch(() => ({})); if (d.error) cam.availability = d.error; }
        updateTile(channel);
      })
      .finally(() => { snapshotQueue.running--; setTileBusy(channel, false); pumpSnapshots(); });
  }
}

function setTileBusy(channel, busy) {
  const tile = document.querySelector(`#cameras .tile[data-ch="${channel}"]`);
  if (tile) tile.querySelector('.state').replaceChildren(busy && !state.snapshots.has(channel) ? h('div', { class: 'spinner' }) : '');
}

function cameraTile(cam) {
  const tile = h('div', { class: 'tile', 'data-ch': cam.channel, role: 'button', tabindex: 0, 'aria-label': `${cam.name} live view` },
    h('img', { class: 'snap', alt: '', draggable: 'false' }),
    h('div', { class: 'state' }),
    h('div', { class: 'label' }, h('span', {}, cam.name), h('span', { class: 'when' })),
    h('div', { class: 'corner' },
      cam.hasSettings ? h('button', { class: 'icon-btn', title: 'Camera settings', 'aria-label': `${cam.name} settings`,
        onclick: (e) => { e.stopPropagation(); openSettings(cam); } }, icon(ICONS.gear)) : null));
  tile.addEventListener('click', () => { if (!arrangeCameras) openLive(cam); });
  tile.addEventListener('keydown', (e) => { if (e.key === 'Enter') openLive(cam); });
  return tile;
}

function updateTile(channel) {
  const tile = document.querySelector(`#cameras .tile[data-ch="${channel}"]`);
  const cam = state.cameras.find(c => c.channel === channel);
  if (!tile || !cam) return;
  const img = tile.querySelector('img.snap');
  const url = state.snapshots.get(channel) || (cam.snapshotAt ? `api/cameras/${channel}/snapshot.jpg?maxAge=1e12&v=${cam.snapshotAt}` : '');
  if (url && img.getAttribute('src') !== url) img.src = url;
  img.hidden = !url;
  tile.querySelector('.when').textContent = cam.snapshotAt ? fmtAgo(cam.snapshotAt) : '';
  tile.querySelector('.badge')?.remove();
  if (cam.availability && cam.availability !== 'online') {
    tile.prepend(h('span', { class: 'badge off' }, cam.availability));
  }
  if (!url && !snapshotQueue.items.some(i => i.channel === channel)) {
    tile.querySelector('.state').replaceChildren(cam.availability && cam.availability !== 'online' ? cam.availability : '');
  }
}

function renderCameras() {
  const view = $('#cameras');
  const size = state.prefs.thumbnailSize || 300;
  tool(
    h('label', { class: 'row small muted hide-phone', title: 'Thumbnail size' }, 'Size',
      h('input', { type: 'range', min: 200, max: 640, step: 20, value: size, style: 'width:110px;accent-color:var(--accent)',
        oninput: (e) => { grid.style.setProperty('--thumb', e.target.value + 'px'); },
        onchange: (e) => savePrefs({ thumbnailSize: Number(e.target.value) }) })),
    h('button', { class: 'btn', 'aria-pressed': arrangeCameras, title: 'Drag cameras into any order',
      onclick: (e) => { arrangeCameras = !arrangeCameras; e.currentTarget.setAttribute('aria-pressed', arrangeCameras); grid.classList.toggle('arranging', arrangeCameras); } },
      icon(ICONS.arrange), h('span', { class: 'hide-phone' }, 'Arrange')),
    refreshButton(async () => {
      await loadCameras();
      renderCamerasGrid(grid);
      for (const cam of ordered()) queueSnapshot(cam.channel, true);
    }));
  const grid = h('div', { class: 'grid' + (arrangeCameras ? ' arranging' : ''), style: `--thumb:${size}px` });
  view.replaceChildren(grid);
  if (isTouch) grid.style.touchAction = '';
  enableDrag(grid, '.tile', (from, to) => { moveCamera(from, to); renderCamerasGrid(grid); });
  renderCamerasGrid(grid);
  for (const cam of ordered()) if (!cam.snapshotAt || Date.now() - cam.snapshotAt > 300000) queueSnapshot(cam.channel, false);
}

function renderCamerasGrid(grid) {
  if (!state.cameras.length) {
    grid.replaceChildren(h('div', { class: 'center', style: 'grid-column: 1 / -1' }, 'No cameras yet.'));
    return;
  }
  grid.replaceChildren(...ordered().map(cameraTile));
  for (const cam of state.cameras) updateTile(cam.channel);
}

// MARK: - Multi-View (an NVR-style wall; every tile is live, muted, and only while this tab is showing)

const LAYOUTS = [
  ['auto', 'Fit All'], ['grid2x2', '2 × 2'], ['grid3x3', '3 × 3'], ['grid4x4', '4 × 4'],
  ['focus1plus3', '1 + 3'], ['focus1plus5', '1 + 5'], ['focus1plus7', '1 + 7'], ['focus2plus8', '2 + 8'],
];

function bestColumns(count, w, hgt) {
  if (count <= 1 || w <= 0 || hgt <= 0) return 1;
  let best = 1, bestWidth = 0;
  for (let columns = 1; columns <= count; columns++) {
    const rows = Math.ceil(count / columns);
    const width = Math.min(w / columns, hgt / rows * 16 / 9);
    if (width > bestWidth) { bestWidth = width; best = columns; }
  }
  return best;
}

function layoutGrid(layout, count, w, hgt) {
  const S = (x, y, width = 1, height = 1) => ({ x, y, width, height });
  const uniform = (n) => [n, n, Array.from({ length: n * n }, (_, i) => S(i % n, Math.floor(i / n)))];
  switch (layout) {
    case 'grid2x2': return uniform(2);
    case 'grid3x3': return uniform(3);
    case 'grid4x4': return uniform(4);
    case 'focus1plus3': return [4, 3, [S(0, 0, 3, 3), S(3, 0), S(3, 1), S(3, 2)]];
    case 'focus1plus5': return [3, 3, [S(0, 0, 2, 2), S(2, 0), S(2, 1), S(0, 2), S(1, 2), S(2, 2)]];
    case 'focus1plus7': return [4, 4, [S(0, 0, 3, 3), S(3, 0), S(3, 1), S(3, 2), S(0, 3), S(1, 3), S(2, 3), S(3, 3)]];
    case 'focus2plus8': return [4, 4, [S(0, 0, 2, 2), S(2, 0, 2, 2), ...Array.from({ length: 8 }, (_, i) => S(i % 4, 2 + Math.floor(i / 4)))]];
    default: {
      const columns = bestColumns(count, w, hgt);
      const rows = Math.max(1, Math.ceil(Math.max(count, 1) / columns));
      return [columns, rows, Array.from({ length: count }, (_, i) => S(i % columns, Math.floor(i / columns)))];
    }
  }
}

function layoutFrames(layout, count, w, hgt, gap) {
  const [columns, rows, slots] = layoutGrid(layout, count, w, hgt);
  const cellW = Math.max(0, Math.min((w - gap * (columns - 1)) / columns, (hgt - gap * (rows - 1)) / rows * 16 / 9));
  const cellH = cellW * 9 / 16;
  const gridW = cellW * columns + gap * (columns - 1), gridH = cellH * rows + gap * (rows - 1);
  // Centred, except when the wall fills the width (a portrait phone): then it starts at the top.
  const ox = (w - gridW) / 2, oy = gridW >= w - 1 ? 0 : Math.max(0, (hgt - gridH) / 2);
  return slots.map(s => ({
    x: ox + s.x * (cellW + gap), y: oy + s.y * (cellH + gap),
    w: s.width * cellW + (s.width - 1) * gap, h: s.height * cellH + (s.height - 1) * gap,
  }));
}

const wall = { el: null, tiles: new Map(), observer: null, arranging: false };

function renderMultiView() {
  leaveMultiView();   // a re-render (tapping the tab again) must not leave tiles on the old wall
  const view = $('#multiview');
  const select = h('select', { class: 'btn', 'aria-label': 'Layout', onchange: (e) => { savePrefs({ layout: e.target.value }); layoutWall(); } },
    LAYOUTS.map(([id, title]) => h('option', { value: id, selected: (state.prefs.layout || 'auto') === id }, title)));
  tool(select,
    isTouch ? h('button', { class: 'btn icon', title: 'Arrange', 'aria-pressed': wall.arranging,
      onclick: (e) => { wall.arranging = !wall.arranging; e.currentTarget.setAttribute('aria-pressed', wall.arranging); wall.el.classList.toggle('arranging', wall.arranging); } }, icon(ICONS.arrange)) : null,
    h('button', { class: 'btn icon', title: 'Full screen', onclick: () => (document.fullscreenElement ? document.exitFullscreen() : view.requestFullscreen?.()) }, icon(ICONS.expand)),
    refreshButton(() => { leaveMultiView(); renderMultiView(); }));
  wall.el = h('div', { class: 'wall' + (wall.arranging ? ' arranging' : '') });
  view.replaceChildren(h('div', { class: 'wall-wrap' }, wall.el));
  enableDrag(wall.el, '.tile', (from, to) => { swapCameras(from, to); layoutWall(); });
  wall.observer = new ResizeObserver(() => layoutWall());
  wall.observer.observe(wall.el);
  if (!state.liveOpen) layoutWall();
}

function wallTile(cam) {
  const status = h('div', { class: 'state' }, h('div', { class: 'spinner' }));
  const video = makeVideo(cam.channel);
  video.addEventListener('state', (e) => {
    if (e.detail === 'playing') status.replaceChildren();
    else if (String(e.detail).startsWith('offline:')) status.replaceChildren(String(e.detail).slice(8));
    else if (String(e.detail).startsWith('error')) status.replaceChildren(String(e.detail).slice(6) || 'Live video unavailable');
  });
  const tile = h('div', { class: 'tile', 'data-ch': cam.channel }, video, status,
    h('div', { class: 'label' }, h('span', {}, cam.name)));
  if (cam.availability && cam.availability !== 'online') status.replaceChildren(cam.availability);
  // No picture after a while: say why, as the HomeBase reports it (offline, switched off, flat battery…).
  let playing = false;
  video.addEventListener('state', (e) => { if (e.detail === 'playing') playing = true; });
  setTimeout(async () => {
    if (playing || !tile.isConnected) return;
    const fresh = await api('cameras').catch(() => null);
    const now = fresh?.find(c => c.channel === cam.channel);
    if (now) Object.assign(cam, now);
    if (!playing && tile.isConnected) status.replaceChildren(now?.availability && now.availability !== 'online' ? now.availability : 'No video from this camera');
  }, 20000);
  tile.addEventListener('click', () => { if (!wall.arranging) openLive(cam); });
  return tile;
}

function layoutWall() {
  if (!wall.el || state.tab !== 'multiview' || state.liveOpen) return;
  const cams = ordered();
  const w = wall.el.clientWidth, hgt = wall.el.clientHeight;
  if (!w || !hgt) return;
  const frames = layoutFrames(state.prefs.layout || 'auto', cams.length, w, hgt, isTouch ? 6 : 8);
  const shown = cams.slice(0, frames.length);
  const keep = new Set(shown.map(c => c.channel));
  for (const [ch, tile] of wall.tiles) if (!keep.has(ch)) { tile.remove(); wall.tiles.delete(ch); }
  wall.el.querySelectorAll('.empty-slot').forEach(e => e.remove());
  frames.forEach((f, i) => {
    const cam = shown[i];
    let el;
    if (cam) {
      el = wall.tiles.get(cam.channel);
      if (!el) { el = wallTile(cam); wall.tiles.set(cam.channel, el); wall.el.append(el); }
    } else {
      el = h('div', { class: 'empty-slot' });
      wall.el.append(el);
    }
    Object.assign(el.style, { left: f.x + 'px', top: f.y + 'px', width: f.w + 'px', height: f.h + 'px' });
  });
  // A portrait phone's "Fit All" is one tall column: let it scroll.
  const bottom = Math.max(0, ...frames.map(f => f.y + f.h));
  wall.el.style.minHeight = bottom > hgt + 1 ? bottom + 'px' : '';
}

/** Leaving Multi-View (or opening one camera) closes every tile's stream. */
function leaveMultiView() {
  wall.observer?.disconnect();
  for (const tile of wall.tiles.values()) tile.remove();
  wall.tiles.clear();
}

// MARK: - Live view (one camera: audio, PTZ, talkback, quality, settings)

function openLive(cam) {
  closeLive();
  if (state.tab === 'multiview') leaveMultiView();
  const status = h('div', { class: 'status' }, h('div', { class: 'spinner' }));
  const video = makeVideo(cam.channel, { audio: true });
  const muteBtn = h('button', { class: 'btn icon', title: 'Sound', 'aria-label': 'Sound' }, icon(ICONS.mute));
  const syncMute = () => {
    const muted = !video.video || video.video.muted;
    muteBtn.replaceChildren(icon(muted ? ICONS.mute : ICONS.sound));
    muteBtn.setAttribute('aria-pressed', !muted);
  };
  muteBtn.addEventListener('click', () => { if (video.video) { video.video.muted = !video.video.muted; video.video.play?.().catch(() => {}); } syncMute(); });
  video.addEventListener('mutechange', syncMute);
  let started = false;
  video.addEventListener('state', (e) => {
    if (e.detail === 'playing') {
      started = true;
      status.replaceChildren();
      // Sound on in single view (the browser may still insist on a tap first).
      if (video.video && video.video.muted && !video.dataset.triedSound) {
        video.dataset.triedSound = '1';
        video.video.muted = false;
        video.video.play().catch(() => { video.video.muted = true; syncMute(); });
      }
      syncMute();
    } else if (e.detail === 'waiting' && started) {
      status.replaceChildren(h('div', { class: 'spinner' }));
    } else if (String(e.detail).startsWith('offline:')) {
      status.replaceChildren(String(e.detail).slice(8));
    } else if (String(e.detail).startsWith('error')) {
      status.replaceChildren('Live video is unavailable right now.');
    }
  });
  const timeout = setTimeout(() => {
    if (!started) status.replaceChildren(h('div', {}, cam.availability && cam.availability !== 'online' ? cam.availability : 'The camera isn\'t sending video yet.',
      h('div', { style: 'margin-top:12px' }, h('button', { class: 'btn', style: 'pointer-events:auto', onclick: () => openLive(cam) }, 'Try again'))));
  }, 25000);

  const quality = cam.qualities ? h('select', { class: 'btn', 'aria-label': 'Quality',
    onchange: (e) => { cam.quality = e.target.value; api(`cameras/${cam.channel}/quality`, { json: { quality: e.target.value } }).catch(() => {}); } },
    cam.qualities.map(q => h('option', { value: q.id, selected: q.id === cam.quality }, q.label))) : null;

  const bottom = h('div', { class: 'bottom' });
  if (cam.ptz) {
    const send = (direction) => api(`cameras/${cam.channel}/ptz`, { json: { direction } }).catch(err => toastText(err.message));
    const pad = h('div', {},
      h('div', { class: 'ptz' },
        h('span'), h('button', { 'aria-label': 'Tilt up', disabled: cam.ptzLocked, onclick: () => send('up') }, icon(ICONS.up)), h('span'),
        h('button', { 'aria-label': 'Pan left', disabled: cam.ptzLocked, onclick: () => send('left') }, icon(ICONS.left)), h('span'),
        h('button', { 'aria-label': 'Pan right', disabled: cam.ptzLocked, onclick: () => send('right') }, icon(ICONS.right)),
        h('span'), h('button', { 'aria-label': 'Tilt down', disabled: cam.ptzLocked, onclick: () => send('down') }, icon(ICONS.down)), h('span')),
      cam.ptzLocked ? h('div', { class: 'hint', style: 'margin-top:6px' }, 'A privacy zone is set on this camera, so it won\'t pan or tilt.') : null,
      cam.ptzLocked ? null : presetRow(cam),
      cam.ptzLocked ? null : panoramaStrip(cam));
    bottom.append(pad);
  } else {
    bottom.append(h('span'));
  }
  bottom.append(h('div', { style: 'display:flex;gap:10px;align-items:flex-end' }, quickRepliesButton(cam), talkbackButton(cam)));

  const live = h('div', { class: 'live', role: 'dialog', 'aria-label': `${cam.name} live` },
    h('div', { class: 'top' },
      h('button', { class: 'btn icon', 'aria-label': 'Back', onclick: closeLive }, icon(ICONS.back)),
      h('h2', {}, cam.name),
      quality, muteBtn,
      cam.hasSettings ? h('button', { class: 'btn icon', 'aria-label': 'Activity zones', title: 'Draw where motion should count', onclick: () => openZoneEditor(cam) }, icon(ICONS.zone || ICONS.gear)) : null,
      h('a', { class: 'btn icon', 'aria-label': 'Save picture', title: 'Save a full-resolution picture',
               href: `api/cameras/${cam.channel}/snapshot.jpg?full=1&fresh=1&settle=0`, download: `${cam.name} ${new Date().toISOString().slice(0, 16)}.jpg` }, icon(ICONS.download)),
      cam.hasSettings ? h('button', { class: 'btn icon', 'aria-label': 'Settings', onclick: () => openSettings(cam) }, icon(ICONS.gear)) : null),
    attachZoom(h('div', { class: 'live-video' }, video, status), video),
    bottom);
  document.body.append(live);
  state.liveOpen = { cam, el: live, cleanup: () => clearTimeout(timeout) };
  history.pushState({ live: cam.channel }, '');
}

/** Activity zones drawn over the camera's latest picture: drag corners, tap an edge to add a corner, double-tap a
 *  corner to remove it. Up to four areas; none means the whole picture counts. */
function openZoneEditor(cam) {
  const wrap = h('div', { class: 'zone-editor' });
  const img = h('img', { src: `api/cameras/${cam.channel}/snapshot.jpg?fresh=1&t=${Date.now()}`, alt: '' });
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 1000 1000'); svg.setAttribute('preserveAspectRatio', 'none');
  wrap.append(img, svg);
  let polygons = [], selected = 0, drag = null;
  const status = h('div', { class: 'small muted' }, 'Loading zones…');
  const el = (n, attrs = {}) => { const e = document.createElementNS('http://www.w3.org/2000/svg', n); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; };
  const toGrid = (e) => { const r = svg.getBoundingClientRect(); return { x: Math.round(Math.max(0, Math.min(1000, (e.clientX - r.left) / r.width * 1000))), y: Math.round(Math.max(0, Math.min(1000, (e.clientY - r.top) / r.height * 1000))) }; };
  const draw = () => {
    svg.replaceChildren();
    polygons.forEach((poly, pi) => {
      const path = el('polygon', { points: poly.map(p => `${p.x},${p.y}`).join(' '), class: pi === selected ? 'zone selected' : 'zone' });
      path.addEventListener('pointerdown', () => { selected = pi; draw(); });
      svg.append(path);
      // Edge midpoints: tap to add a corner there.
      poly.forEach((p, i) => {
        const q = poly[(i + 1) % poly.length];
        const mid = el('circle', { cx: (p.x + q.x) / 2, cy: (p.y + q.y) / 2, r: 12, class: 'zone-mid' });
        mid.addEventListener('pointerdown', (e) => { e.stopPropagation(); poly.splice(i + 1, 0, { x: Math.round((p.x + q.x) / 2), y: Math.round((p.y + q.y) / 2) }); selected = pi; draw(); });
        svg.append(mid);
      });
      poly.forEach((p, i) => {
        const dot = el('circle', { cx: p.x, cy: p.y, r: 16, class: 'zone-pt' });
        dot.addEventListener('pointerdown', (e) => { e.stopPropagation(); selected = pi; drag = { pi, i }; svg.setPointerCapture(e.pointerId); });
        dot.addEventListener('dblclick', () => { if (poly.length > 3) { poly.splice(i, 1); draw(); } });
        svg.append(dot);
      });
    });
    status.textContent = polygons.length ? `${polygons.length} zone${polygons.length === 1 ? '' : 's'}. Drag corners; tap an edge to add one; double-tap a corner to remove it.` : 'No zones: the whole picture counts. Add one to limit where motion matters.';
  };
  svg.addEventListener('pointermove', (e) => { if (!drag) return; const g = toGrid(e); polygons[drag.pi][drag.i] = g; draw(); });
  svg.addEventListener('pointerup', () => { drag = null; });
  const addBtn = h('button', { class: 'btn', onclick: () => { if (polygons.length >= 4) return toastText('Up to four zones'); polygons.push([{ x: 300, y: 300 }, { x: 700, y: 300 }, { x: 700, y: 700 }, { x: 300, y: 700 }]); selected = polygons.length - 1; draw(); } }, 'Add zone');
  const delBtn = h('button', { class: 'btn', onclick: () => { if (polygons.length) { polygons.splice(selected, 1); selected = 0; draw(); } } }, 'Remove selected');
  const saveBtn = h('button', { class: 'btn primary', onclick: async () => {
    saveBtn.disabled = true; status.textContent = 'Sending to the camera…';
    try { const r = await api(`cameras/${cam.channel}/zones`, { json: { polygons } }); if (r.ok) { toastText('Zones saved'); closeOverlay(); } else { status.textContent = r.message || 'The camera did not take the zones'; } }
    catch (err) { status.textContent = err.message; } finally { saveBtn.disabled = false; }
  } }, 'Save');
  openOverlay(sheet(`${cam.name} · Activity zones`, h('div', {}, wrap, status, h('div', { style: 'display:flex;gap:8px;margin-top:10px' }, addBtn, delBtn, h('span', { class: 'spacer' }), saveBtn)), { wide: true }));
  api(`cameras/${cam.channel}/zones`).then(r => { polygons = r.polygons || []; draw(); }).catch(err => { status.textContent = err.message; });
}

/** Saved positions 1–4 (tap to go, long-press to save the current view there) and the home position to return to. */
function presetRow(cam) {
  const base = `cameras/${cam.channel}/ptz`;
  const row = h('div', { class: 'presets' });
  let saved = [], home = null;
  const draw = () => {
    row.replaceChildren(...[0, 1, 2, 3].map(i => {
      const b = h('button', { class: 'btn small', 'aria-pressed': saved.includes(i) ? 'true' : 'false', title: saved.includes(i) ? `Go to position ${i + 1} (hold to save the current view here)` : `Hold to save the current view as position ${i + 1}` }, String(i + 1));
      let timer = null, held = false;
      const down = () => { held = false; timer = setTimeout(() => { held = true; api(`${base}/preset`, { json: { action: 'save', index: i } }).then(r => { saved = r.presets; draw(); toastText(`Saved position ${i + 1}`); }).catch(err => toastText(err.message)); }, 700); };
      const up = () => { clearTimeout(timer); if (!held && saved.includes(i)) api(`${base}/preset`, { json: { action: 'go', index: i } }).catch(err => toastText(err.message)); };
      b.addEventListener('pointerdown', down); b.addEventListener('pointerup', up); b.addEventListener('pointerleave', () => clearTimeout(timer));
      return b;
    }), h('select', { class: 'btn small', 'aria-label': 'Home position', title: 'Return to this position a few minutes after any move',
      onchange: (e) => api(`${base}/home`, { method: 'PUT', json: { index: e.target.value === '' ? null : Number(e.target.value), minutes: home?.minutes || 5 } }).then(r => { home = r.home; draw(); }).catch(err => toastText(err.message)) },
      h('option', { value: '', selected: !home }, 'Home: off'), ...saved.map(i => h('option', { value: i, selected: home?.index === i }, `Home: ${i + 1}`))),
      home ? h('select', { class: 'btn small', 'aria-label': 'Return after', onchange: (e) => api(`${base}/home`, { method: 'PUT', json: { index: home.index, minutes: Number(e.target.value) } }).then(r => { home = r.home; draw(); }) },
        ...[1, 2, 5, 10, 30].map(m => h('option', { value: m, selected: home.minutes === m }, `${m} min`))) : null);
  };
  api(`${base}/preset`).then(r => { saved = r.presets || []; home = r.home || null; draw(); }).catch(() => draw());
  draw();
  return row;
}

/** Stored messages ("Leave the package by the door") played through the camera's speaker. */
function quickRepliesButton(cam) {
  const base = `cameras/${cam.channel}/replies`;
  const btn = h('button', { class: 'btn icon', 'aria-label': 'Quick replies', title: 'Play a stored message through the camera' }, icon(ICONS.chat || ICONS.mic));
  btn.onclick = async () => {
    const { replies } = await api(base).catch(() => ({ replies: [] }));
    const list = h('div', { class: 'card' });
    const draw = (names) => list.replaceChildren(...(names.length ? names.map(n => h('div', { class: 'setting' }, h('div', { class: 'name' }, n),
      h('div', { style: 'display:flex;gap:6px' },
        h('button', { class: 'btn small primary', onclick: () => api(`${base}/play`, { json: { name: n } }).then(() => toastText(`Playing “${n}”`)).catch(err => toastText(err.message)) }, 'Play'),
        h('button', { class: 'btn small', onclick: () => api(base + `?name=${encodeURIComponent(n)}`, { method: 'DELETE' }).then(r => draw(r.replies)) }, 'Delete')))) :
      [h('div', { class: 'center muted' }, 'No replies yet. Record one below.')]));
    draw(replies);
    const name = h('input', { type: 'text', placeholder: 'Name, e.g. Leave the package', class: 'btn', style: 'flex:1' });
    let rec = null;
    const recBtn = h('button', { class: 'btn' }, 'Record');
    recBtn.onclick = async () => {
      if (rec) { rec.stop(); return; }
      if (!name.value.trim()) return toastText('Give the reply a name first');
      try {
        const media = await navigator.mediaDevices.getUserMedia({ audio: true });
        const ctx = new AudioContext({ sampleRate: 16000 });
        const src = ctx.createMediaStreamSource(media), proc = ctx.createScriptProcessor(4096, 1, 1);
        const chunks = [];
        proc.onaudioprocess = (e) => { const f = e.inputBuffer.getChannelData(0); const i16 = new Int16Array(f.length); for (let i = 0; i < f.length; i++) i16[i] = Math.max(-1, Math.min(1, f[i])) * 32767; chunks.push(i16); };
        src.connect(proc); proc.connect(ctx.destination);
        recBtn.textContent = 'Stop';
        rec = { stop: async () => {
          proc.disconnect(); src.disconnect(); media.getTracks().forEach(t => t.stop()); await ctx.close(); rec = null; recBtn.textContent = 'Record';
          const total = chunks.reduce((n, c) => n + c.length, 0), pcm = new Int16Array(total); let o = 0; for (const c of chunks) { pcm.set(c, o); o += c.length; }
          const r = await fetch(`api/${base}/upload?name=${encodeURIComponent(name.value.trim())}&format=pcm`, { method: 'POST', body: pcm.buffer }).then(r => r.json());
          if (r.replies) { draw(r.replies); toastText('Saved'); } else toastText(r.error || 'Could not save');
        } };
      } catch (err) { toastText('Microphone unavailable: ' + err.message); }
    };
    openOverlay(sheet('Quick replies', h('div', {}, list, h('div', { style: 'display:flex;gap:8px;margin-top:12px' }, name, recBtn),
      h('p', { class: 'small muted' }, 'Replies play through the camera’s speaker while its live view is open.'))));
  };
  return btn;
}

/** The camera's panorama (built by panning a step at a time): tap a spot to point the camera there. */
function panoramaStrip(cam) {
  const base = `cameras/${cam.channel}/panorama`;
  const wrap = h('div', { class: 'panorama' });
  const button = h('button', { class: 'btn', style: 'margin-top:8px' }, 'Panorama');
  const view = h('div', { class: 'panorama-view', hidden: true });
  let polling = null;
  const show = (status) => {
    if (status.state === 'running') {
      button.disabled = true;
      button.textContent = `Panning… ${Math.round((status.progress || 0) * 100)}%`;
      return;
    }
    button.disabled = false;
    button.textContent = status.state === 'done' ? 'New panorama' : 'Panorama';
    if (status.state === 'failed') toastText(status.message || 'Couldn\'t make a panorama');
    if (status.state !== 'done') return;
    const img = h('img', { src: `api/${base}.jpg?t=${status.createdAt}`, alt: `${cam.name} panorama`, draggable: false });
    const marker = h('div', { class: 'panorama-marker' });
    const place = (x) => { marker.style.left = `${x * 100}%`; };
    if (status.current != null) place(status.current);
    img.onclick = (e) => {
      const x = (e.clientX - img.getBoundingClientRect().left) / img.getBoundingClientRect().width;
      place(x);
      api(`${base}/aim`, { json: { x } }).then(s => s.current != null && place(s.current)).catch(err => toastText(err.message));
    };
    view.replaceChildren(h('div', { class: 'panorama-inner' }, img, marker),
      h('div', { class: 'hint' }, 'Tap a spot to point the camera there.'));
    view.hidden = false;
  };
  const poll = () => api(base).then(status => {
    show(status);
    clearTimeout(polling);
    if (status.state === 'running') polling = setTimeout(poll, 1500);
  }).catch(() => {});
  button.onclick = () => api(base, { json: {} }).then(poll).catch(err => toastText(err.message));
  poll();
  wrap.append(button, view);
  return wrap;
}

/** Zoom into the live picture on the viewer's side (the camera keeps sending its full picture): pinch or
 *  scroll to zoom, drag to pan, double-tap to reset. Sharper than the camera's own zoom, which crops before
 *  encoding, and free on battery. */
function attachZoom(container, video) {
  let scale = 1, tx = 0, ty = 0;
  const pointers = new Map();
  let pinch = null, drag = null, lastTap = 0;
  const badge = h('div', { class: 'zoom-badge', hidden: true });
  container.append(badge);
  const apply = () => {
    const w = container.clientWidth, h = container.clientHeight;
    tx = Math.min(0, Math.max(w - w * scale, tx));
    ty = Math.min(0, Math.max(h - h * scale, ty));
    video.style.transformOrigin = '0 0';
    video.style.transform = scale === 1 ? '' : `translate(${tx}px, ${ty}px) scale(${scale})`;
    badge.hidden = scale === 1;
    badge.textContent = `${scale.toFixed(1)}×`;
  };
  const zoomAt = (factor, cx, cy) => {
    const next = Math.min(8, Math.max(1, scale * factor));
    // Keep the point under the cursor (or between the fingers) where it is.
    tx = cx - (cx - tx) * (next / scale);
    ty = cy - (cy - ty) * (next / scale);
    scale = next;
    if (scale === 1) { tx = 0; ty = 0; }
    apply();
  };
  const local = (e) => { const r = container.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  container.addEventListener('wheel', (e) => {
    e.preventDefault();
    const [cx, cy] = local(e);
    zoomAt(Math.exp(-e.deltaY * 0.002), cx, cy);
  }, { passive: false });
  container.addEventListener('pointerdown', (e) => {
    pointers.set(e.pointerId, local(e));
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      pinch = { dist: Math.hypot(a[0] - b[0], a[1] - b[1]), scale };
      drag = null;
    } else if (pointers.size === 1 && scale > 1) {
      drag = { x: e.clientX - tx, y: e.clientY - ty, moved: false };
    }
  });
  container.addEventListener('pointermove', (e) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, local(e));
    if (pinch && pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      const dist = Math.hypot(a[0] - b[0], a[1] - b[1]);
      const factor = (pinch.scale * dist / pinch.dist) / scale;
      zoomAt(factor, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2);
      e.preventDefault();
    } else if (drag) {
      tx = e.clientX - drag.x; ty = e.clientY - drag.y; drag.moved = true;
      apply();
      e.preventDefault();
    }
  });
  const up = (e) => {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
    if (pointers.size === 0) {
      const now = Date.now();
      if (!drag?.moved && now - lastTap < 350) { scale = 1; tx = 0; ty = 0; apply(); }
      lastTap = now;
      drag = null;
    }
  };
  container.addEventListener('pointerup', up);
  container.addEventListener('pointercancel', up);
  container.style.touchAction = 'none';
  return container;
}

function closeLive(fromHistory) {
  const open = state.liveOpen;
  if (!open) return;
  state.liveOpen = null;
  open.cleanup();
  open.stopTalk?.();
  open.el.remove();
  if (fromHistory !== true && history.state?.live != null) history.back();
  if (state.tab === 'multiview') renderMultiView();
}
window.addEventListener('popstate', () => { if (state.liveOpen) closeLive(true); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { if (!$('#overlay').hidden) closeOverlay(); else closeLive(); } });

/** Hold to talk: the mic as 16 kHz PCM, sent in short chunks; the bridge encodes it for the camera's speaker. */
function talkbackButton(cam) {
  const wrap = h('div', { style: 'display:flex;flex-direction:column;align-items:center;gap:6px' });
  if (!navigator.mediaDevices?.getUserMedia) {
    // The Home Assistant app gives the microphone only to its own page, not to this frame: ask the panel (the
    // parent page) whether it can talk for us.
    if (window.parent !== window) {
      const ask = (e) => {
        if (e.origin !== location.origin || e.data?.type !== 'eufynized-mic') return;
        window.removeEventListener('message', ask);
        if (e.data.available) wrap.replaceChildren(...parentTalkButton(cam).childNodes);
        else wrap.replaceChildren(h('div', { class: 'hint', style: 'text-align:right' }, 'This app doesn\'t allow the microphone here.'));
      };
      window.addEventListener('message', ask);
      window.parent.postMessage({ type: 'eufynized-mic-probe' }, location.origin);
      setTimeout(() => window.removeEventListener('message', ask), 3000);
    }
    // Browsers only offer the microphone on secure (https) pages; on the home Wi-Fi the Home Assistant app
    // may be on its local http:// address.
    const why = !window.isSecureContext
      ? `Talking needs https. This page is on ${location.host} (plain http), probably the app's home Wi-Fi address.`
      : 'This app doesn\'t let the page use the microphone.';
    wrap.append(h('div', { class: 'hint', style: 'text-align:right' }, why));
    return wrap;
  }
  const btn = h('button', { class: 'talk', 'aria-label': 'Hold to talk' }, icon(ICONS.mic));
  wrap.append(btn, h('div', { class: 'hint' }, 'Hold to talk'));
  let session = null;
  const start = async (e) => {
    e.preventDefault();
    if (session) return;
    session = { chunks: [], stopped: false };
    btn.classList.add('on');
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      if (session.stopped) { media.getTracks().forEach(t => t.stop()); return; }
      await api(`cameras/${cam.channel}/talkback/start`, { method: 'POST' });
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const source = ctx.createMediaStreamSource(media);
      const processor = ctx.createScriptProcessor(4096, 1, 1);
      const ratio = ctx.sampleRate / 16000;
      processor.onaudioprocess = (ev) => {
        const input = ev.inputBuffer.getChannelData(0);
        const out = new Int16Array(Math.floor(input.length / ratio));
        for (let i = 0; i < out.length; i++) out[i] = Math.max(-1, Math.min(1, input[Math.floor(i * ratio)])) * 0x7fff;
        session?.chunks.push(out);
      };
      source.connect(processor); processor.connect(ctx.destination);
      const timer = setInterval(() => {
        if (!session?.chunks.length) return;
        const total = session.chunks.reduce((n, c) => n + c.length, 0);
        const merged = new Int16Array(total); let o = 0;
        for (const c of session.chunks) { merged.set(c, o); o += c.length; }
        session.chunks = [];
        fetch(`api/cameras/${cam.channel}/talkback/audio`, { method: 'POST', body: merged.buffer }).catch(() => {});
      }, 250);
      Object.assign(session, { media, ctx, processor, timer });
      if (session.stopped) stop();
    } catch (err) {
      toastText(err.message || 'Microphone unavailable');
      stop();
    }
  };
  const stop = () => {
    if (!session) return;
    const s = session;
    s.stopped = true;
    if (!s.media && !s.ctx) { btn.classList.remove('on'); session = null; return; }
    session = null;
    btn.classList.remove('on');
    clearInterval(s.timer);
    s.processor?.disconnect(); s.ctx?.close(); s.media?.getTracks().forEach(t => t.stop());
    api(`cameras/${cam.channel}/talkback/stop`, { method: 'POST' }).catch(() => {});
  };
  btn.addEventListener('pointerdown', start);
  btn.addEventListener('pointerup', stop);
  btn.addEventListener('pointerleave', stop);
  btn.addEventListener('pointercancel', stop);
  btn.addEventListener('contextmenu', (e) => e.preventDefault());
  queueMicrotask(() => { if (state.liveOpen) state.liveOpen.stopTalk = stop; });
  return wrap;
}

/** Hold to talk through the Home Assistant panel, which owns the microphone in the HA app. */
function parentTalkButton(cam) {
  const btn = h('button', { class: 'talk', 'aria-label': 'Hold to talk' }, icon(ICONS.mic));
  const hint = h('div', { class: 'hint' }, 'Hold to talk');
  const wrap = h('div', {}, btn, hint);
  const send = (action) => window.parent.postMessage({ type: 'eufynized-talk', action, channel: cam.channel }, location.origin);
  const onState = (e) => {
    if (e.origin !== location.origin || e.data?.type !== 'eufynized-talk-state') return;
    btn.classList.toggle('on', !!e.data.on);
    if (e.data.error) toastText(`Talk: ${e.data.error}`);
  };
  window.addEventListener('message', onState);
  let held = false;
  const start = (e) => { e.preventDefault(); if (held) return; held = true; btn.classList.add('on'); send('start'); };
  const stop = () => { if (!held) return; held = false; btn.classList.remove('on'); send('stop'); };
  btn.addEventListener('pointerdown', start);
  btn.addEventListener('pointerup', stop);
  btn.addEventListener('pointerleave', stop);
  btn.addEventListener('pointercancel', stop);
  btn.addEventListener('contextmenu', (e) => e.preventDefault());
  queueMicrotask(() => {
    if (!state.liveOpen) return;
    const previous = state.liveOpen.stopTalk;
    state.liveOpen.stopTalk = () => { previous?.(); stop(); window.removeEventListener('message', onState); };
  });
  return wrap;
}

// MARK: - Overlay sheets

function openOverlay(sheet) {
  const overlay = $('#overlay');
  overlay.replaceChildren(sheet);
  overlay.hidden = false;
  overlay.onclick = (e) => { if (e.target === overlay) closeOverlay(); };
}
function closeOverlay() {
  const overlay = $('#overlay');
  overlay.dispatchEvent(new Event('close'));
  overlay.hidden = true;
  overlay.replaceChildren();
}

function sheet(title, body, { wide = false, actions = [] } = {}) {
  return h('div', { class: 'sheet' + (wide ? ' wide' : ''), role: 'dialog', 'aria-label': title },
    h('header', {}, h('h2', {}, title), ...actions,
      h('button', { class: 'btn icon', 'aria-label': 'Close', onclick: closeOverlay }, icon(ICONS.close))),
    h('div', { class: 'body' }, body));
}

// MARK: - Camera settings (read live from the HomeBase; each change is read back to confirm)

function openSettings(cam) {
  const body = h('div', {});
  const reload = h('button', { class: 'btn icon', 'aria-label': 'Reload', title: 'Reload', onclick: () => load() }, icon(ICONS.refresh));
  openOverlay(sheet(`${cam.name} Settings`, body, { actions: [reload] }));
  let groups = null, message = null;
  const pending = new Set();

  const load = async () => {
    body.replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' }), 'Reading settings from the HomeBase…'));
    try {
      groups = (await api(`cameras/${cam.channel}/settings`)).groups;
      message = null;
      render();
    } catch (err) {
      body.replaceChildren(h('div', { class: 'center' }, h('b', {}, 'Couldn\'t read settings'), err.message,
        h('button', { class: 'btn', onclick: load }, 'Try Again')));
    }
  };

  const write = async (setting, value) => {
    pending.add(setting.id); message = null; render();
    try {
      const res = await api(`cameras/${cam.channel}/settings`, { json: { id: setting.id, value } });
      if (res.groups) groups = res.groups;
      message = res.message || null;
    } catch (err) {
      message = err.message;
    }
    pending.delete(setting.id); render();
  };

  const control = (s) => {
    const busy = pending.has(s.id);
    const row = (cls, ...kids) => h('div', { class: `setting ${cls || ''}${busy ? ' busy' : ''}` }, ...kids);
    const name = h('div', { class: 'name' }, s.label);
    const unit = s.unit ? ' ' + s.unit : '';
    if (s.kind === 'toggle' && typeof s.value === 'boolean') {
      if (!s.editable) return row('', name, h('span', { class: 'value' }, s.value ? 'On' : 'Off'));
      return row('', name, h('label', { class: 'switch' },
        h('input', { type: 'checkbox', checked: s.value, disabled: busy, 'aria-label': s.label, onchange: (e) => write(s, e.target.checked ? 1 : 0) }), h('span')));
    }
    if (s.kind === 'choice') {
      const known = s.options.some(o => o.value === s.value);
      if (!s.editable) return row('', name, h('span', { class: 'value' }, s.options.find(o => o.value === s.value)?.label ?? `Custom (${s.value})`));
      return row('', name, h('select', { class: 'btn', disabled: busy, 'aria-label': s.label, onchange: (e) => write(s, Number(e.target.value)) },
        s.options.map(o => h('option', { value: o.value, selected: o.value === s.value }, o.label)),
        known ? null : h('option', { value: s.value, selected: true }, `Custom (${s.value})`)));
    }
    if (s.kind === 'number' && s.editable && s.supportedValues) {
      return row('', name, h('select', { class: 'btn', disabled: busy, 'aria-label': s.label, onchange: (e) => write(s, Number(e.target.value)) },
        s.supportedValues.map(v => h('option', { value: v, selected: v === s.value }, `${v}${unit}`))));
    }
    if (s.kind === 'number' && s.editable && s.min != null && s.max != null) {
      const shown = h('span', { class: 'value' }, `${s.value}${unit}`);
      return row('slider', name, shown, h('input', { type: 'range', min: s.min, max: s.max, step: s.step || 1, value: s.value, disabled: busy, 'aria-label': s.label,
        oninput: (e) => { shown.textContent = `${e.target.value}${unit}`; },
        onchange: (e) => write(s, Number(e.target.value)) }));
    }
    const text = typeof s.value === 'boolean' ? (s.value ? 'On' : 'Off') : `${s.value}${s.kind === 'number' ? unit : ''}`;
    return row('', name, h('span', { class: 'value' }, text));
  };

  const render = () => {
    if (!groups) return;
    body.replaceChildren(
      message ? h('div', { class: 'banner' }, message) : '',
      ...(groups.length ? groups.flatMap(g => [h('div', { class: 'group-title' }, g.group), h('div', { class: 'card' }, g.settings.map(control))])
        : [h('div', { class: 'center' }, 'No settings for this camera yet.')]),
      h('p', { class: 'small muted' }, 'Read live from your HomeBase. Each change is read back from the camera to confirm it took.'));
  };
  load();
}

// MARK: - Events (the HomeBase's own recordings: range, camera and kind filters, snapshots, clips)

const KINDS = [['person', 'Person'], ['motion', 'Motion'], ['ring', 'Doorbell'], ['sensor', 'Sensor'], ['other', 'Other']];
const startOfDay = (d) => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };
const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
const sameDay = (a, b) => a && b && startOfDay(a).getTime() === startOfDay(b).getTime();
const ev = { start: startOfDay(new Date()), end: startOfDay(new Date()), camera: 'all', kinds: new Set(), items: null, error: null, shown: 120, loading: false, token: 0 };

function rangeLabel() {
  const today = startOfDay(new Date());
  const f = (d) => d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  if (sameDay(ev.start, ev.end)) {
    if (sameDay(ev.start, today)) return 'Today';
    if (sameDay(ev.start, addDays(today, -1))) return 'Yesterday';
    return f(ev.start);
  }
  return `${f(ev.start)} – ${f(ev.end)}`;
}

async function loadEvents() {
  const token = ++ev.token;
  ev.loading = true; ev.error = null; ev.items = null; ev.shown = 120;
  drawEvents();
  try {
    const to = Math.min(Date.now(), addDays(ev.end, 1).getTime() - 1);
    const data = await api(`events?from=${ev.start.getTime()}&to=${to}`);
    if (token !== ev.token) return;
    ev.items = data.events || [];
  } catch (err) {
    if (token !== ev.token) return;
    ev.error = err.message;
  }
  ev.loading = false;
  drawEvents();
}

function renderEvents() {
  tool(refreshButton(loadEvents));
  const view = $('#events');
  view.replaceChildren(h('div', { class: 'filters', id: 'ev-filters' }), h('div', { id: 'ev-list' }));
  drawFilters();
  if (!ev.items && !ev.loading) loadEvents(); else drawEvents();
}

function drawFilters() {
  const bar = $('#ev-filters');
  if (!bar) return;
  const rangeBtn = h('button', { class: 'btn', 'aria-haspopup': 'dialog', onclick: (e) => openCalendar(e.currentTarget) }, icon(ICONS.calendar), rangeLabel());
  const cams = h('select', { class: 'btn', 'aria-label': 'Camera', onchange: (e) => { ev.camera = e.target.value; drawEvents(); } },
    h('option', { value: 'all' }, 'All cameras'),
    ordered().map(c => h('option', { value: c.serial, selected: ev.camera === c.serial }, c.name)));
  const chips = KINDS.map(([id, label]) => h('button', { class: 'chip', 'aria-pressed': ev.kinds.has(id),
    onclick: () => { ev.kinds.has(id) ? ev.kinds.delete(id) : ev.kinds.add(id); drawFilters(); drawEvents(); } }, label));
  bar.replaceChildren(rangeBtn, cams, ...chips);
}

function filteredEvents() {
  return (ev.items || []).filter(e => (ev.camera === 'all' || e.serial === ev.camera) && (!ev.kinds.size || ev.kinds.has(e.kind)));
}

function drawEvents() {
  const list = $('#ev-list');
  if (!list) return;
  if (ev.loading) return list.replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' }), 'Reading events from the HomeBase…'));
  if (ev.error) return list.replaceChildren(h('div', { class: 'center' }, h('b', {}, 'Couldn\'t read events'), ev.error, h('button', { class: 'btn', onclick: loadEvents }, 'Try Again')));
  const items = filteredEvents();
  if (!items.length) return list.replaceChildren(h('div', { class: 'center' }, 'No events in this range.'));
  const out = [h('div', { class: 'small muted' }, `${items.length} event${items.length === 1 ? '' : 's'}`)];
  let day = null, grid = null;
  for (const e of items.slice(0, ev.shown)) {
    const d = new Date(e.start);
    if (!sameDay(d, day)) {
      day = d;
      const dayItems = items.filter(x => sameDay(new Date(x.start), d));
      const dayCams = [...new Map(dayItems.map(x => [x.channel, x.camera])).entries()];
      out.push(h('div', { class: 'day', style: 'display:flex;align-items:center;gap:10px' },
        d.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' }),
        h('span', { class: 'spacer' }),
        dayCams.length ? h('button', { class: 'btn small', onclick: () => chooseTimelapse(d, dayCams, dayItems) }, icon(ICONS.timelapse || ICONS.play || ICONS.calendar), ' Time-lapse') : null));
      out.push(timelineStrip(d, dayItems));
      grid = h('div', { class: 'events-grid' });
      out.push(grid);
    }
    const secs = Math.max(0, Math.round((e.end - e.start) / 1000));
    const thumb = h('div', { class: 'thumb' },
      e.thumb ? h('img', { loading: 'lazy', alt: '', src: `api/events/image?path=${encodeURIComponent(e.thumb)}` }) : null,
      h('span', { class: 'dur' }, secs >= 60 ? `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}` : `${secs}s`));
    const card = h('button', { class: 'event', onclick: () => openClip(e) }, thumb,
      h('div', { class: 'meta' }, h('b', {}, fmtTime(e.start)), h('span', { class: 'muted' }, e.camera), h('span', { class: `kind ${e.kind}` }, e.label)));
    attachHoverPreview(card, thumb, e);
    grid.append(card);
  }
  if (items.length > ev.shown) out.push(h('div', { class: 'center' }, h('button', { class: 'btn', onclick: () => { ev.shown += 120; drawEvents(); } }, `Show more (${items.length - ev.shown} left)`)));
  list.replaceChildren(...out);
}

/** The day as one strip per camera: each recording is a bar you can click, placed by its time. A camera that
 *  recorded continuously that day shows the holes in its coverage in red. */
function timelineStrip(day, items) {
  const dayStart = startOfDay(day).getTime(), dayMs = 86400000;
  const pct = (t) => `${Math.max(0, Math.min(100, (t - dayStart) / dayMs * 100))}%`;
  const byCam = new Map();
  for (const e of items) { if (!byCam.has(e.camera)) byCam.set(e.camera, []); byCam.get(e.camera).push(e); }
  const lanes = [...byCam.entries()].map(([camera, list]) => {
    list.sort((a, b) => a.start - b.start);
    const lane = h('div', { class: 'tl-lane' }, h('span', { class: 'tl-name' }, camera));
    // Continuous recording: at least one long record that day. Gaps longer than two minutes get flagged.
    const continuous = list.some(e => e.end - e.start >= 10 * 60000);
    if (continuous) {
      const now = Date.now(), endOfCover = Math.min(now, dayStart + dayMs);
      let cursor = Math.max(dayStart, list[0].start);
      for (const e of list) {
        if (e.start - cursor > 2 * 60000) lane.append(h('span', { class: 'tl-gap', style: `left:${pct(cursor)};width:${pct(e.start - dayStart + dayStart) === pct(cursor) ? '0.2%' : ((e.start - cursor) / dayMs * 100) + '%'}`, title: `No recording ${fmtTime(cursor)}–${fmtTime(e.start)}` }));
        cursor = Math.max(cursor, e.end);
      }
      if (endOfCover - cursor > 2 * 60000) lane.append(h('span', { class: 'tl-gap', style: `left:${pct(cursor)};width:${(endOfCover - cursor) / dayMs * 100}%`, title: `No recording since ${fmtTime(cursor)}` }));
    }
    lane.append(h('button', { class: 'tl-play', title: `${camera}: play this day as a time-lapse`, 'aria-label': `${camera} time-lapse`,
      onclick: () => openTimelapse(list[0].channel, camera, day) }, '▶'));
    for (const e of list) {
      lane.append(h('span', { class: `tl-seg ${e.kind}`, style: `left:${pct(e.start)};width:${Math.max(0.25, (e.end - e.start) / dayMs * 100)}%`,
        title: `${fmtTime(e.start)} · ${e.label}` }));
    }
    return lane;
  });
  const hours = h('div', { class: 'tl-hours' }, ...[0, 6, 12, 18, 24].map(hh => h('span', { style: `left:${hh / 24 * 100}%` }, hh === 24 ? '' : `${hh}:00`)));
  const strip = h('div', { class: 'timeline' }, hours, ...lanes);
  if (sameDay(day, new Date())) strip.append(h('span', { class: 'tl-now', style: `left:${pct(Date.now())}` }));
  attachScrubber(strip, lanes, [...byCam.values()], dayStart, dayMs);
  return strip;
}

/** The playhead: drag along the strip and a readout follows with the time and the picture from the recording
 *  under your finger (the lane you're on, else the nearest). Let go on a recording and it opens, cued to that moment. */
function attachScrubber(strip, laneEls, laneLists, dayStart, dayMs) {
  const head = h('div', { class: 'tl-head', hidden: true });
  const readout = h('div', { class: 'tl-readout', hidden: true });
  const readTime = h('b'), readCam = h('span', { class: 'muted' }), readImg = h('img', { alt: '' });
  readout.append(readImg, h('div', {}, readTime, ' ', readCam));
  // The loupe: the whole day drawn once as a long track (40 minutes = the strip's width), slid under a window
  // with a transform. Nothing is rebuilt while the finger moves.
  const LOUPE_MS = 40 * 60000, SCALE = dayMs / LOUPE_MS;
  const loupe = h('div', { class: 'tl-loupe', hidden: true });
  const track = h('div', { class: 'tl-loupe-track' });
  const loupeTime = h('span', { class: 'tl-loupe-time' });
  const loupeHint = h('span', { class: 'tl-loupe-hint' }, 'slide up or down for finer control');
  loupe.append(track, loupeTime, h('span', { class: 'tl-loupe-center' }), loupeHint);
  strip.append(head, readout, loupe);
  let built = false, width = 0, active = false, current = null, pending = null, raf = 0, lastRec = null;
  const buildTrack = () => {
    width = (laneEls[0] || strip).getBoundingClientRect().width;
    track.style.width = `${width * SCALE}px`;
    track.replaceChildren(...laneLists.map((list, i) => h('div', { class: 'tl-loupe-lane', 'data-lane': i },
      ...list.map(x => h('span', { class: `tl-seg ${x.kind}`, style: `left:${(x.start - dayStart) / dayMs * 100}%;width:${Math.max(0.02, (x.end - x.start) / dayMs * 100)}%` })))));
    // Lane names ride along outside the track so they stay put.
    loupe.querySelectorAll('.tl-loupe-name').forEach(n => n.remove());
    laneLists.forEach((_, i) => loupe.append(h('span', { class: 'tl-loupe-name', style: `top:${14 + i * 10}px` }, laneEls[i].querySelector('.tl-name')?.textContent || '')));
    built = true;
  };
  // Like the Photos app: the playhead sits under the finger and follows it one-to-one along the strip. Slide the
  // finger upward, away from the strip, and the same sideways movement scrubs finer (down to the loupe's
  // scale, seconds per pixel), so short clips can be landed on.
  let t = dayStart, lastX = null, msPerPx = 0;
  const laneRect = () => (laneEls[0] || strip).getBoundingClientRect();
  const coarseMsPerPx = () => dayMs / laneRect().width;
  const place = (clientX, clientY) => {
    const r = laneRect();
    // Distance from the lanes, above or below: the page is a frame inside the Home Assistant app and there's
    // little room above the strip, so sliding down into the cards works the same as sliding up.
    const away = Math.max(0, r.top - clientY, clientY - r.bottom);
    const precision = Math.min(1, Math.max(0, (away - 14) / 110));    // 0 on the strip … 1 about 125 px away
    // Exponential, like Photos: minutes per pixel on the strip, down to one second per pixel at the top.
    msPerPx = coarseMsPerPx() * Math.pow(1000 / coarseMsPerPx(), precision);
    if (lastX === null || precision === 0) t = dayStart + Math.max(0, Math.min(1, (clientX - r.left) / r.width)) * dayMs;
    else t = Math.max(dayStart, Math.min(dayStart + dayMs, t + (clientX - lastX) * msPerPx));
    lastX = clientX;
    return { t, x: (t - dayStart) / dayMs * r.width + (r.left - strip.getBoundingClientRect().left), precision };
  };
  const laneAt = (clientY) => laneEls.findIndex(l => { const r = l.getBoundingClientRect(); return clientY >= r.top && clientY <= r.bottom; });
  const recordingAt = (t, laneIndex) => {
    const order = laneIndex >= 0 ? [laneIndex, ...laneLists.map((_, i) => i).filter(i => i !== laneIndex)] : laneLists.map((_, i) => i);
    for (const i of order) { const hit = laneLists[i].find(x => t >= x.start && t <= x.end); if (hit) return hit; }
    if (laneIndex >= 0) {
      // Snap within three pixels at the current scale (seconds when scrubbing slowly, minutes when fast).
      const near = laneLists[laneIndex].reduce((best, x) => (!best || Math.abs(x.start - t) < Math.abs(best.start - t)) ? x : best, null);
      if (near && Math.abs(near.start - t) < Math.max(20000, 3 * msPerPx)) return near;
    }
    return null;
  };
  const paint = () => {
    raf = 0;
    if (!pending) return;
    const { t, x, lane } = pending;
    head.style.transform = `translateX(${x}px)`;
    // Slide the track so the finger's time sits under the centre line.
    track.style.transform = `translateX(${width / 2 - (t - dayStart) / dayMs * width * SCALE}px)`;
    loupe.querySelectorAll('.tl-loupe-lane').forEach((el, i) => el.classList.toggle('current', i === lane));
    loupeTime.textContent = new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', second: '2-digit' });
    const rec = recordingAt(t, lane);
    current = rec ? { rec, t: (t >= rec.start && t <= rec.end) ? t : rec.start } : null;
    readTime.textContent = loupeTime.textContent;
    if (rec !== lastRec) {
      lastRec = rec;
      readCam.textContent = rec ? `${rec.camera} · ${rec.label}` : 'no recording';
      if (rec && rec.thumb) { readImg.src = `api/events/image?path=${encodeURIComponent(rec.thumb)}`; readImg.hidden = false; } else readImg.hidden = true;
    }
    const sw = strip.getBoundingClientRect().width;
    readout.style.transform = `translateX(${Math.max(0, Math.min(sw - 190, x - 90))}px)`;
  };
  const move = (e) => {
    const { t, x, precision } = place(e.clientX, e.clientY);
    loupe.classList.toggle('precise', precision > 0.05);
    loupeHint.textContent = precision > 0.05 ? (msPerPx >= 60000 ? `${Math.round(msPerPx / 60000)} min per pixel` : `${Math.max(1, Math.round(msPerPx / 1000))} s per pixel`) + ' · further away = finer' : 'slide up or down for finer control';
    const lane = laneAt(e.clientY);
    pending = { t, x, lane: lane >= 0 ? lane : (pending ? pending.lane : -1) };
    if (!raf) raf = requestAnimationFrame(paint);
  };
  strip.addEventListener('pointerdown', (e) => {
    if (e.target.closest('.tl-play')) return;
    if (!built) buildTrack();
    active = true; lastRec = undefined; lastX = null; strip.setPointerCapture(e.pointerId);
    head.hidden = false; readout.hidden = false; loupe.hidden = false;
    move(e); e.preventDefault();
  });
  strip.addEventListener('pointermove', (e) => { if (active) move(e); });
  const end = () => {
    if (!active) return;
    active = false;
    if (raf) { cancelAnimationFrame(raf); raf = 0; paint(); }
    head.hidden = true; readout.hidden = true; loupe.hidden = true;
    if (current) openClip(current.rec, (current.t - current.rec.start) / 1000);
  };
  strip.addEventListener('pointerup', end);
  strip.addEventListener('pointercancel', () => { active = false; head.hidden = true; readout.hidden = true; loupe.hidden = true; });
  window.addEventListener('resize', () => { built = false; });
}

/** Hover a card for a moment and its clip plays silently in place of the picture (mouse only). Clips the
 *  HomeBase hasn't sent yet are fetched one at a time, so hovering across the grid can't open a session per card. */
const previewQueue = { busy: false, waiting: [] };
function attachHoverPreview(card, thumb, e) {
  if (!window.matchMedia('(hover: hover) and (pointer: fine)').matches) return;
  const url = `api/events/clip.mp4?channel=${e.channel}&path=${encodeURIComponent(e.path)}`;
  let timer = null, video = null, cancelled = false;
  const ready = async () => (await api(`events/clip-progress?path=${encodeURIComponent(e.path)}`).catch(() => ({}))).ready;
  const fetchOne = () => new Promise(resolve => {
    previewQueue.waiting.push(async () => { await fetch(url, { headers: { Range: 'bytes=0-0' } }).catch(() => {}); resolve(); });
    pumpPreviews();
  });
  const show = () => {
    if (cancelled || video) return;
    video = h('video', { src: url, muted: true, autoplay: true, loop: true, playsinline: true, class: 'preview' });
    thumb.append(video);
  };
  card.addEventListener('mouseenter', () => {
    cancelled = false;
    timer = setTimeout(async () => {
      if (await ready()) return show();
      await fetchOne();
      if (!cancelled && await ready()) show();
    }, 700);
  });
  card.addEventListener('mouseleave', () => { cancelled = true; clearTimeout(timer); if (video) { video.remove(); video = null; } });
}
async function pumpPreviews() {
  if (previewQueue.busy) return;
  const next = previewQueue.waiting.shift();
  if (!next) return;
  previewQueue.busy = true;
  try { await next(); } finally { previewQueue.busy = false; pumpPreviews(); }
}

/** Which camera's day to play: one big button per camera, with how many recordings it has that day. */
function chooseTimelapse(day, dayCams, dayItems) {
  const list = h('div', { class: 'card' }, ...dayCams.map(([ch, name]) => {
    const n = dayItems.filter(x => x.channel === ch).length;
    return h('button', { class: 'setting', style: 'width:100%;text-align:left;cursor:pointer', onclick: () => { closeOverlay(); openTimelapse(ch, name, day); } },
      h('div', { class: 'name' }, name, h('div', { class: 'small muted' }, `${n} recording${n === 1 ? '' : 's'} · about ${Math.max(5, Math.round(n / 5))} s of video`)),
      icon(ICONS.play || ICONS.right));
  }));
  openOverlay(sheet(`Time-lapse · ${day.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}`,
    h('div', {}, h('p', { class: 'small muted' }, 'The whole day in about 30 seconds: one picture from each recording, in order. Pick a camera.'), list)));
}

/** Asks the bridge for a day's time-lapse and plays it when it's ready. */
function openTimelapse(channel, camera, day) {
  const date = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
  const body = h('div', { class: 'player' }, h('div', { class: 'center' }, h('div', { class: 'spinner' }), 'Collecting the day’s pictures from the HomeBase…'));
  const title = `${camera} · ${day.toLocaleDateString([], { month: 'long', day: 'numeric' })} in 30 seconds`;
  const url = `api/cameras/${channel}/timelapse.mp4?date=${date}`;
  const download = h('a', { class: 'btn icon', href: url, download: `${camera} ${date} time-lapse.mp4`, 'aria-label': 'Download', title: 'Download' }, icon(ICONS.download));
  openOverlay(sheet(title, body, { wide: true, actions: [download] }));
  let stopped = false;
  const poll = async () => {
    const s = await api(`cameras/${channel}/timelapse?date=${date}`).catch(() => ({ state: 'failed', message: 'The bridge did not answer' }));
    if (stopped) return;
    if (s.state === 'done') body.replaceChildren(h('video', { src: `${url}&t=${Date.now()}`, controls: true, autoplay: true, playsinline: true, muted: true }));
    else if (s.state === 'failed') body.replaceChildren(h('div', { class: 'center' }, s.message || 'Could not make the time-lapse'));
    else { body.querySelector('.center')?.append(h('div', { class: 'small muted' }, `${s.frames || 0} pictures so far`)); setTimeout(poll, 2000); }
  };
  api(`cameras/${channel}/timelapse`, { json: { date, seconds: 30 } }).then(poll).catch(err => body.replaceChildren(h('div', { class: 'center' }, err.message)));
  $('#overlay').addEventListener('close', () => { stopped = true; }, { once: true });
}

/** One calendar, pick a range like Google Flights: first click starts it, second ends it. */
function openCalendar(anchor) {
  document.querySelector('.popover')?.remove();
  let month = new Date(ev.end.getFullYear(), ev.end.getMonth(), 1);
  let start = ev.start, end = ev.end, hover = null, picking = false;
  const today = startOfDay(new Date());
  const pop = h('div', { class: 'popover', role: 'dialog', 'aria-label': 'Choose dates' });
  const apply = () => { ev.start = start; ev.end = end; pop.remove(); drawFilters(); loadEvents(); };
  const draw = () => {
    const first = new Date(month);
    const gridStart = addDays(first, -first.getDay());
    const days = [];
    for (let d = gridStart; d < addDays(new Date(month.getFullYear(), month.getMonth() + 1, 1), 0) || days.length % 7; d = addDays(d, 1)) days.push(d);
    const bandEnd = picking ? (hover && hover >= start ? hover : start) : end;
    const nextDisabled = month.getFullYear() === today.getFullYear() && month.getMonth() === today.getMonth();
    pop.replaceChildren(
      h('div', { class: 'cal-head' }, h('span', { class: 'spacer' }, month.toLocaleDateString([], { month: 'long', year: 'numeric' })),
        h('button', { class: 'btn icon', 'aria-label': 'Previous month', onclick: () => { month = new Date(month.getFullYear(), month.getMonth() - 1, 1); draw(); } }, icon(ICONS.left)),
        h('button', { class: 'btn icon', 'aria-label': 'Next month', disabled: nextDisabled, onclick: () => { month = new Date(month.getFullYear(), month.getMonth() + 1, 1); draw(); } }, icon(ICONS.right))),
      h('div', { class: 'cal' },
        ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map(d => h('div', { class: 'dow' }, d)),
        days.map(d => {
          const inBand = d >= start && d <= bandEnd && !sameDay(start, bandEnd);
          const cls = [d.getMonth() !== month.getMonth() ? 'out' : '', sameDay(d, today) ? 'today' : '',
            inBand ? 'band' : '', sameDay(d, start) ? 'start edge' : '', sameDay(d, bandEnd) ? 'end edge' : ''].join(' ');
          return h('button', { class: cls, disabled: d > today, 'aria-label': d.toDateString(),
            onclick: () => {
              if (!picking || d < start) { start = d; end = d; picking = true; }
              else { end = d; picking = false; apply(); return; }
              draw();
            },
            onpointerenter: () => { if (picking) { hover = d; draw(); } } }, h('span', {}, d.getDate()));
        })),
      h('div', { class: 'presets' },
        [['Today', 0, 0], ['Yesterday', -1, -1], ['Last 3 days', -2, 0], ['Last 7 days', -6, 0]].map(([label, a, b]) =>
          h('button', { class: 'chip', onclick: () => { start = addDays(today, a); end = addDays(today, b); apply(); } }, label)),
        picking ? h('button', { class: 'chip', 'aria-pressed': true, onclick: () => { end = start; picking = false; apply(); } }, 'Just this day') : null));
  };
  draw();
  document.body.append(pop);
  const r = anchor.getBoundingClientRect();
  pop.style.top = `${r.bottom + 6 + window.scrollY}px`;
  pop.style.left = `${Math.max(8, Math.min(r.left, innerWidth - 308))}px`;
  setTimeout(() => {
    const away = (e) => { if (!pop.contains(e.target)) { pop.remove(); document.removeEventListener('pointerdown', away); } };
    document.addEventListener('pointerdown', away);
  });
}

/** Plays an event's clip: the bridge downloads it from the HomeBase once (with progress), then serves an MP4. */
function openClip(e, seekSeconds = 0) {
  const url = `api/events/clip.mp4?channel=${e.channel}&path=${encodeURIComponent(e.path)}`;
  const bar = h('div', {});
  const progress = h('div', { class: 'progress' }, bar);
  const body = h('div', { class: 'player' }, h('div', { class: 'center' }, h('div', { class: 'spinner' }), 'Fetching the clip from the HomeBase…', progress));
  const title = `${e.camera} · ${e.label} · ${new Date(e.start).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}`;
  const download = h('a', { class: 'btn icon', href: url, download: `${e.camera} ${new Date(e.start).toISOString().slice(0, 16)}.mp4`, 'aria-label': 'Download', title: 'Download' }, icon(ICONS.download));
  openOverlay(sheet(title, body, { wide: true, actions: [download] }));
  let done = false;
  $('#overlay').addEventListener('close', () => { done = true; }, { once: true });
  const poll = async () => {
    if (done) return;
    try {
      const p = await api(`events/clip-progress?path=${encodeURIComponent(e.path)}`);
      if (p.ready) return play();
      if (e.bytes) bar.style.width = `${Math.min(100, (p.bytes / e.bytes) * 100)}%`;
    } catch {}
    setTimeout(poll, 1000);
  };
  const play = () => {
    if (done) return;
    done = true;
    const video = h('video', { src: url, controls: true, autoplay: true, playsinline: true });
    if (seekSeconds > 0) video.addEventListener('loadedmetadata', () => { video.currentTime = Math.min(seekSeconds, Math.max(0, video.duration - 1)); }, { once: true });
    body.replaceChildren(video);
  };
  // Starting the request kicks off the download; progress is polled alongside it.
  fetch(url, { headers: { Range: 'bytes=0-0' } }).then(r => { if (r.ok) play(); else if (!done) body.replaceChildren(h('div', { class: 'center' }, 'The HomeBase didn\'t send this clip. Try again in a moment.')); }).catch(() => {});
  setTimeout(poll, 800);
}

// MARK: - Alerts

const alertState = { recent: [], settings: null, status: '' };
const ALERT_KINDS = [['motion', 'Motion'], ['person', 'Person'], ['pet', 'Pet'], ['vehicle', 'Vehicle'], ['sound', 'Sound / crying'], ['doorbell', 'Doorbell']];

async function loadAlerts() {
  const data = await api('alerts');
  alertState.recent = data.recent; alertState.settings = data.settings; alertState.status = data.status;
}

function renderAlerts() {
  tool(refreshButton(async () => { await loadAlerts().catch(() => {}); drawAlerts(); }));
  $('#alerts').replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' })));
  loadAlerts().then(drawAlerts).catch(err => $('#alerts').replaceChildren(h('div', { class: 'center' }, err.message)));
}

function drawAlerts() {
  if (state.tab !== 'alerts' || !alertState.settings) return;
  const s = alertState.settings;
  const save = (update) => api('alerts/settings', { method: 'PUT', json: update }).then(r => { alertState.settings = r; drawAlerts(); }).catch(err => toastText(err.message));
  const sw = (checked, onchange, label, disabled) => h('label', { class: 'switch' }, h('input', { type: 'checkbox', checked, disabled, 'aria-label': label, onchange }), h('span'));
  const setting = (label, control, sub) => h('div', { class: 'setting' }, h('div', { class: 'name' }, label, sub ? h('div', { class: 'small muted' }, sub) : null), control);
  const kinds = new Set(s.kinds), muted = new Set(s.mutedChannels);
  const left = h('div', {},
    h('div', { class: 'group-title' }, 'Alerts'),
    h('div', { class: 'card' },
      setting('Show event alerts', sw(s.enabled, (e) => save({ enabled: e.target.checked }), 'Show event alerts'),
        `Announced by the HomeBase over your network the moment it happens. Watcher: ${alertState.status}.`),
      setting('Push to phone', sw(s.push, (e) => save({ push: e.target.checked }), 'Push to phone', !s.notifyService),
        s.notifyService ? `Through notify.${s.notifyService.replace(/^notify\./, '')}` : 'Set notify_service under eufynized: in configuration.yaml (for example mobile_app_your_iphone).')),
    h('div', { class: 'group-title' }, 'Kinds'),
    h('div', { class: 'card' }, ALERT_KINDS.map(([id, label]) => setting(label, sw(kinds.has(id), (e) => {
      e.target.checked ? kinds.add(id) : kinds.delete(id); save({ kinds: [...kinds] });
    }, label, !s.enabled)))),
    h('div', { class: 'group-title' }, 'Cameras'),
    h('div', { class: 'card' }, ordered().map(c => setting(c.name, sw(!muted.has(c.channel), (e) => {
      e.target.checked ? muted.delete(c.channel) : muted.add(c.channel); save({ mutedChannels: [...muted] });
    }, c.name, !s.enabled)))),
    h('div', { class: 'group-title' }, 'Quiet hours'),
    h('div', { class: 'card' },
      setting('Hold camera alerts', sw(!!s.quietHours, (e) => save({ quietHours: e.target.checked ? { start: '22:00', end: '07:00' } : null }), 'Quiet hours'),
        'No camera-event alerts between these times. Health alerts and the digest still come.'),
      s.quietHours ? h('div', { class: 'setting' }, h('div', { class: 'name' }, 'From / to'),
        h('div', { style: 'display:flex;gap:8px' },
          h('input', { type: 'time', value: s.quietHours.start, onchange: (e) => save({ quietHours: { ...s.quietHours, start: e.target.value } }) }),
          h('input', { type: 'time', value: s.quietHours.end, onchange: (e) => save({ quietHours: { ...s.quietHours, end: e.target.value } }) }))) : null),
    h('div', { class: 'group-title' }, 'Per-camera alert windows'),
    h('div', { class: 'card' }, ordered().map(c => {
      const win = (s.schedules || {})[String(c.channel)];
      return setting(c.name, h('div', { style: 'display:flex;gap:6px;align-items:center' },
        h('input', { type: 'time', value: win?.start || '', 'aria-label': `${c.name} alerts from`, onchange: (e) => saveWindow(c.channel, { ...(win || { end: '23:59' }), start: e.target.value }) }),
        h('span', { class: 'muted' }, '–'),
        h('input', { type: 'time', value: win?.end || '', 'aria-label': `${c.name} alerts to`, onchange: (e) => saveWindow(c.channel, { ...(win || { start: '00:00' }), end: e.target.value }) }),
        win ? h('button', { class: 'btn small', onclick: () => saveWindow(c.channel, null) }, 'Always') : null),
        win ? `Alerts only ${win.start}–${win.end}` : 'Alerts at any time');
    })),
    h('div', { class: 'group-title' }, 'Morning digest'),
    h('div', { class: 'card' },
      setting('Send a daily summary', sw(s.digestTime !== 'off', (e) => save({ digestTime: e.target.checked ? '07:00' : 'off' }), 'Daily digest'),
        'Recordings per camera, batteries and drive space, once a day.'),
      s.digestTime !== 'off' ? setting('At', h('input', { type: 'time', value: s.digestTime, onchange: (e) => save({ digestTime: e.target.value }) })) : null,
      h('div', { style: 'margin-top:8px' }, h('button', { class: 'btn', onclick: () => api('alerts/digest', { method: 'POST' }).then(() => toastText('Digest on its way')).catch(err => toastText(err.message)) }, 'Send the digest now'))),
    h('div', { style: 'margin-top:14px' }, h('button', { class: 'btn primary', onclick: () => api('alerts/test', { method: 'POST' }).catch(err => toastText(err.message)) }, 'Send Test Alert')),
    h('p', { class: 'small muted' }, `Every event also fires eufynized_event in Home Assistant, for your own automations.${s.falseAlarms ? ` ${s.falseAlarms} alert${s.falseAlarms === 1 ? '' : 's'} marked as false alarms.` : ''}`));
  function saveWindow(channel, win) {
    const schedules = { ...(s.schedules || {}) };
    if (win) schedules[String(channel)] = win; else delete schedules[String(channel)];
    save({ schedules });
  }
  const right = h('div', {},
    h('div', { class: 'group-title' }, 'Recent'),
    alertState.recent.length
      ? h('div', { class: 'card' }, alertState.recent.map(a => h('div', { class: 'alert-row', onclick: () => { const cam = state.cameras.find(c => c.channel === a.channel); if (cam) openLive(cam); } },
          h('span', { class: 'dot' }), h('div', { class: 'spacer' }, h('b', {}, a.title), ' · ', a.camera, a.detail ? h('div', { class: 'small muted', style: 'white-space:pre-line' }, a.detail) : null), h('span', { class: 'small muted' }, fmtAgo(a.time)))))
      : h('div', { class: 'card' }, h('div', { class: 'center' }, 'No alerts since the add-on started.')));
  $('#alerts').replaceChildren(h('div', { class: 'alerts-layout' }, left, right));
}

// MARK: - Toasts (live alerts while the page is open)

function toastText(text) {
  const t = h('div', { class: 'toast' }, h('div', {}, text));
  $('#toasts').append(t);
  setTimeout(() => t.remove(), 5000);
  t.onclick = () => t.remove();
}

function toastAlert(a) {
  const cam = state.cameras.find(c => c.channel === a.channel);
  const t = h('div', { class: 'toast', role: 'status' },
    h('img', { alt: '', src: `api/cameras/${a.channel}/snapshot.jpg?maxAge=1e12&v=${Date.now()}` }),
    h('div', {}, h('b', {}, `${a.title} · ${a.camera}`), h('div', { class: 'small muted' }, fmtTime(a.time))));
  t.onclick = () => { t.remove(); if (cam) openLive(cam); };
  $('#toasts').prepend(t);
  setTimeout(() => t.remove(), 8000);
}

function listenForAlerts() {
  let lastSeen = Date.now();
  const onAlert = (a) => {
    if (a.time <= lastSeen && !String(a.id).startsWith('test-')) return;
    lastSeen = Math.max(lastSeen, a.time);
    alertState.recent.unshift(a);
    if (state.tab === 'alerts') drawAlerts();
    if (alertState.settings?.enabled !== false) toastAlert(a);
  };
  let polling = null;
  const poll = () => api('alerts').then(d => {
    alertState.settings = d.settings;
    for (const a of [...d.recent].reverse()) if (a.time > lastSeen) onAlert(a);
  }).catch(() => {});
  try {
    const source = new EventSource('api/alerts/stream');
    source.onmessage = (m) => {
      try {
        const data = JSON.parse(m.data);
        onAlert(data);
      } catch {}
    };
    source.onerror = () => { if (!polling) polling = setInterval(poll, 15000); };
    source.onopen = () => { if (polling) { clearInterval(polling); polling = null; } };
  } catch {
    polling = setInterval(poll, 15000);
  }
}

// MARK: - Inside Home Assistant

// In Home Assistant's sidebar panel on a phone, HA's own menu button is hidden behind this page: offer one that
// asks the panel (the parent page) to open HA's sidebar.
if (window.parent !== window) {
  const menu = $('#ha-menu');
  const sync = () => { menu.hidden = !matchMedia('(max-width: 870px)').matches; };
  sync();
  matchMedia('(max-width: 870px)').addEventListener('change', sync);
  menu.addEventListener('click', () => window.parent.postMessage({ type: 'eufynized-toggle-menu' }, location.origin));
}

// MARK: - Start

async function loadCameras() {
  const [cameras, prefs] = await Promise.all([api('cameras', { timeout: 15000 }), api('prefs', { timeout: 15000 }).catch(() => ({}))]);
  state.cameras = cameras;
  Object.assign(state.prefs, prefs);
}

// First run: the bridge has no key yet. Sign in with the eufy account once, right here; the bridge fetches the
// key and the camera list, saves them, and restarts. The password goes to the bridge over the local network and
// from there to eufy only; nothing is kept.
async function setupIfNeeded() {
  let s;
  try { s = await api('setup', { timeout: 8000 }); } catch { return false; }
  if (s.configured) return false;
  document.querySelector('.tabs').hidden = true;
  $('#tools').replaceChildren();
  for (const view of document.querySelectorAll('.view')) view.hidden = view.id !== 'cameras';
  renderSetup(s);
  return true;
}

function renderSetup(s) {
  const root = $('#cameras');
  const field = (label, input) => h('label', { class: 'field' }, h('span', {}, label), input);
  const busy = (text) => h('div', { class: 'center' }, h('div', { class: 'spinner' }), h('span', {}, text));
  const post = async (path, json) => {
    try { renderSetup(await api('setup/' + path, { json })); poll(); }
    catch (err) { renderSetup({ ...s, state: 'failed', message: err.message }); }
  };
  let body;
  if (s.state === 'working') body = busy(s.message || 'Working…');
  else if (s.state === 'done') body = busy(s.message || 'Starting…');
  else if (s.state === 'captcha') {
    const answer = h('input', { type: 'text', autocomplete: 'off', autocapitalize: 'off', required: true });
    body = h('form', { class: 'setup-form', onsubmit: (e) => { e.preventDefault(); post('captcha', { answer: answer.value }); } },
      h('p', {}, s.message),
      s.captcha ? h('img', { class: 'captcha', src: 'data:image/png;base64,' + s.captcha, alt: 'captcha' }) : null,
      field('Characters shown', answer),
      h('button', { class: 'btn primary', type: 'submit' }, 'Continue'));
  } else if (s.state === 'code') {
    const code = h('input', { type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', required: true });
    body = h('form', { class: 'setup-form', onsubmit: (e) => { e.preventDefault(); post('code', { code: code.value }); } },
      h('p', {}, s.message),
      field('Verification code', code),
      h('button', { class: 'btn primary', type: 'submit' }, 'Continue'));
  } else {
    const email = h('input', { type: 'email', autocomplete: 'username', required: true, value: store.get('setupEmail', '') });
    const password = h('input', { type: 'password', autocomplete: 'current-password', required: true });
    const ip = h('input', { type: 'text', inputmode: 'decimal', placeholder: '192.168.1.50', required: true, value: store.get('setupIP', '') });
    const country = h('input', { type: 'text', value: 'US', maxlength: 2, style: 'width:4em', autocapitalize: 'characters' });
    body = h('form', { class: 'setup-form', onsubmit: (e) => {
        e.preventDefault(); store.set('setupEmail', email.value); store.set('setupIP', ip.value);
        post('login', { email: email.value, password: password.value, homeBaseIP: ip.value, country: country.value });
      } },
      s.state === 'failed' ? h('p', { class: 'error' }, s.message) : null,
      field('eufy account email', email),
      field('Password', password),
      field('HomeBase IP address', ip),
      field('Country code', country),
      h('button', { class: 'btn primary', type: 'submit' }, 'Sign in'),
      h('p', { class: 'small' }, 'Sent to eufy once to fetch the key that unlocks your cameras\' video. Not stored. The HomeBase\'s address is in your router\'s device list (HomeBase or T8030).'));
  }
  root.replaceChildren(h('div', { class: 'setup' },
    h('h1', {}, 'Set up Eufynized'),
    h('p', { class: 'lead' }, 'Your cameras, straight from the HomeBase on your own network. One sign-in to get started.'),
    body));
  function poll() {
    setTimeout(async () => {
      let n; try { n = await api('setup', { timeout: 8000 }); } catch { n = null; }
      if (n && n.configured) { location.reload(); return; }
      if (!n) { setTimeout(() => location.reload(), 3000); return; }   // the bridge is restarting
      if (n.state === 'working' || n.state === 'done') { renderSetup(n); poll(); }
      else if (n.state !== s.state) renderSetup(n);
    }, 1200);
  }
  if (s.state === 'working' || s.state === 'done') poll();
}

async function start() {
  if (await setupIfNeeded()) return;
  if (!state.cameras.length) {
    $('#cameras').hidden = false;
    $('#cameras').replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' }), 'Connecting…'));
  }
  try {
    await loadCameras();
  } catch (err) {
    // Shown on whichever tab is open, and retried by itself (the bridge may be restarting after an update).
    for (const view of document.querySelectorAll('.view')) view.hidden = view.id !== state.tab;
    $(`#${state.tab}`).replaceChildren(h('div', { class: 'center' }, h('div', { class: 'spinner' }),
      h('b', {}, 'Waiting for Eufynized…'), h('span', { class: 'small' }, err.message)));
    setTimeout(start, 3000);
    return;
  }
  api('alerts').then(d => { alertState.settings = d.settings; alertState.recent = d.recent; alertState.status = d.status; }).catch(() => {});
  listenForAlerts();
  showTab(state.tab);
}

// Coming back to the page refreshes stale pictures; going away lets every stream stop.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (state.tab === 'cameras') for (const cam of state.cameras) if (!cam.snapshotAt || Date.now() - cam.snapshotAt > 300000) queueSnapshot(cam.channel, false);
});

start();
