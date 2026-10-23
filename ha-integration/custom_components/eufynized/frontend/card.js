// `custom:eufynized-card`: the Eufynized page inside a dashboard (Overview), opening on a chosen tab.
//
//   type: custom:eufynized-card
//   view: multiview          # cameras | multiview | events | alerts (default multiview)
//   height: 70vh             # any CSS height (default: the screen's height below the dashboard's header)
import { EufynizedFrame } from './frame.js';

class EufynizedCard extends EufynizedFrame {
  setConfig(config) {
    this._config = { view: 'multiview', ...config };
  }

  get frameQuery() { return `?view=${encodeURIComponent(this._config?.view || 'multiview')}&embed=1`; }

  applyStyle() {
    this.style.display = 'block';
  }

  mount(frame) {
    const card = document.createElement('ha-card');
    card.style.cssText = 'overflow:hidden;border-radius:var(--ha-card-border-radius,12px)';
    const height = this._config?.height;
    // By default the card fills the screen below the dashboard's header and the section heading, so a portrait
    // phone shows a full Multi-View wall instead of a short 16:10 strip.
    frame.style.cssText = `border:0;width:100%;display:block;min-height:360px;height:${height || 'calc(100dvh - 190px)'}`;
    card.append(frame);
    this.replaceChildren(card);
  }

  getCardSize() { return 8; }
  getGridOptions() { return { columns: 'full', min_columns: 6, rows: 'auto' }; }
  static getStubConfig() { return { view: 'multiview' }; }
}

customElements.define('eufynized-card', EufynizedCard);
window.customCards = window.customCards || [];
window.customCards.push({ type: 'eufynized-card', name: 'Eufynized', description: 'Your eufy cameras: Multi-View, cameras, events.' });
