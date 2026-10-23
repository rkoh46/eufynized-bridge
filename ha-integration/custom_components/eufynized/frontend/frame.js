// Shared by the Security Camera sidebar panel and the dashboard card: a frame showing the Eufynized page,
// reached through a session path that the signed-in user's websocket hands out (so the page sits behind Home
// Assistant's login).
//
// It also talks for the page: the Home Assistant iOS app gives the microphone only to its own top-level page,
// not to frames, so the page asks this element to capture the mic and send it to the camera.
export class EufynizedFrame extends HTMLElement {
  /** Query added to the page URL (e.g. "?view=multiview&embed=1"). */
  get frameQuery() { return ''; }

  set hass(hass) {
    const first = !this._hass;
    this._hass = hass;
    if (first) this._open();
  }

  set narrow(value) { this._narrow = value; }

  connectedCallback() {
    this.applyStyle();
    this._onMessage = (e) => {
      if (e.origin !== location.origin || !this._frame || e.source !== this._frame.contentWindow) return;
      const msg = e.data || {};
      if (msg.type === 'eufynized-toggle-menu') {
        this.dispatchEvent(new Event('hass-toggle-menu', { bubbles: true, composed: true }));
      } else if (msg.type === 'eufynized-mic-probe') {
        this._reply({ type: 'eufynized-mic', available: !!navigator.mediaDevices?.getUserMedia, secure: window.isSecureContext });
      } else if (msg.type === 'eufynized-talk') {
        if (msg.action === 'start') this._startTalk(msg.channel);
        else this._stopTalk();
      }
    };
    window.addEventListener('message', this._onMessage);
    if (this._hass && !this._frame) this._open();
  }

  applyStyle() {}

  disconnectedCallback() {
    window.removeEventListener('message', this._onMessage);
    this._stopTalk();
  }

  mount(frame) { this.replaceChildren(frame); }

  _reply(message) { this._frame?.contentWindow?.postMessage(message, location.origin); }

  async _open() {
    if (!this.isConnected || this._opening) return;
    this._opening = true;
    try {
      const { path } = await this._hass.callWS({ type: 'eufynized/session' });
      this._path = path;
      const frame = document.createElement('iframe');
      frame.src = path + this.frameQuery;
      frame.title = 'Security Camera';
      frame.allow = 'microphone; fullscreen; autoplay';
      frame.allowFullscreen = true;
      frame.style.cssText = 'border:0;width:100%;height:100%;display:block';
      this.mount(frame);
      this._frame = frame;
    } catch (err) {
      this.textContent = `Couldn't open Security Camera: ${err.message || err}`;
    } finally {
      this._opening = false;
    }
  }

  /** Hold-to-talk on the page's behalf: the mic as 16 kHz PCM in short chunks; the bridge encodes it for the camera. */
  async _startTalk(channel) {
    if (this._talk) return;
    const talk = this._talk = { channel, chunks: [], stopped: false };
    const base = `${this._path}api/cameras/${channel}/talkback`;
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      talk.media = media;
      if (talk.stopped) { this._cleanup(talk); this._talk = null; return; }
      const res = await fetch(`${base}/start`, { method: 'POST' });
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `HTTP ${res.status}`);
      const ctx = talk.ctx = new (window.AudioContext || window.webkitAudioContext)();
      const source = ctx.createMediaStreamSource(media);
      const processor = talk.processor = ctx.createScriptProcessor(4096, 1, 1);
      const ratio = ctx.sampleRate / 16000;
      processor.onaudioprocess = (ev) => {
        const input = ev.inputBuffer.getChannelData(0);
        const out = new Int16Array(Math.floor(input.length / ratio));
        for (let i = 0; i < out.length; i++) out[i] = Math.max(-1, Math.min(1, input[Math.floor(i * ratio)])) * 0x7fff;
        talk.chunks.push(out);
      };
      source.connect(processor);
      processor.connect(ctx.destination);
      talk.timer = setInterval(() => {
        if (!talk.chunks.length) return;
        const total = talk.chunks.reduce((n, c) => n + c.length, 0);
        const merged = new Int16Array(total);
        let offset = 0;
        for (const c of talk.chunks) { merged.set(c, offset); offset += c.length; }
        talk.chunks = [];
        fetch(`${base}/audio`, { method: 'POST', body: merged.buffer }).catch(() => {});
      }, 250);
      this._reply({ type: 'eufynized-talk-state', on: true });
      if (talk.stopped) this._stopTalk();
    } catch (err) {
      this._reply({ type: 'eufynized-talk-state', on: false, error: err.message || String(err) });
      this._cleanup(talk);
      if (this._talk === talk) this._talk = null;
    }
  }

  _stopTalk() {
    const talk = this._talk;
    if (!talk) return;
    talk.stopped = true;
    if (!talk.media) return;   // still starting: it stops itself once the mic opens
    this._talk = null;
    this._cleanup(talk);
    fetch(`${this._path}api/cameras/${talk.channel}/talkback/stop`, { method: 'POST' }).catch(() => {});
    this._reply({ type: 'eufynized-talk-state', on: false });
  }

  _cleanup(talk) {
    clearInterval(talk.timer);
    talk.processor?.disconnect();
    talk.ctx?.close().catch(() => {});
    talk.media?.getTracks().forEach((t) => t.stop());
  }
}
