(() => {
  'use strict';
  // This script runs in WKContentWorld.defaultClient, not in the website's JavaScript world.
  // It observes native scheduling only. It does not replace page APIs or intercept input.
  if (globalThis.__pagekeepConfigure) return;
  let state = __CONFIG__;
  const frameID = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : String(Math.random());
  let timeoutID = 0, frameHandle = 0, running = false;
  let started = 0, lastTick = 0, lastReport = 0, ticks = 0, frames = 0, largestGap = 0;
  function send(payload) {
    try { window.webkit.messageHandlers.pagekeep.postMessage({ ...payload, frameID }); } catch (_) {}
  }
  function stop() {
    running = false;
    clearTimeout(timeoutID); cancelAnimationFrame(frameHandle);
    timeoutID = frameHandle = 0;
  }
  function start() {
    stop(); running = true;
    started = lastTick = lastReport = performance.now(); ticks = frames = 0; largestGap = 0;
    const frame = () => { if (!running) return; frames++; frameHandle = requestAnimationFrame(frame); };
    const tick = () => {
      if (!running) return;
      const now = performance.now(); ticks++;
      largestGap = Math.max(largestGap, (now - lastTick) / 1000); lastTick = now;
      if (now - lastReport >= 2000) {
        send({ kind: 'probe', elapsed: (now - started) / 1000, ticks, frames, gap: largestGap, realHidden: document.hidden });
        lastReport = now;
      }
      timeoutID = setTimeout(tick, 100);
    };
    frameHandle = requestAnimationFrame(frame); timeoutID = setTimeout(tick, 100);
  }
  Object.defineProperty(globalThis, '__pagekeepConfigure', { value(next) {
    const wasEnabled = !!state.probe;
    state = { ...state, ...next };
    if (!!state.probe !== wasEnabled) { if (state.probe) start(); else stop(); }
    send({ kind: 'applied', continuous: !!state.continuous, observationOnly: true });
  }});
  const ready = () => send({ kind: 'ready' });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();
  window.addEventListener('pagehide', stop, { once: true });
  if (state.probe) start();
})();
