// The Security Camera sidebar panel: the Eufynized page, full screen.
import { EufynizedFrame } from './frame.js';

class EufynizedPanel extends EufynizedFrame {
  applyStyle() {
    // The panel's host doesn't always give it a height (the iOS app), which left the frame at its 150px default:
    // fill the viewport instead.
    this.style.cssText = 'display:block;height:100vh;height:100dvh;background:var(--primary-background-color)';
  }
}

customElements.define('eufynized-panel', EufynizedPanel);
