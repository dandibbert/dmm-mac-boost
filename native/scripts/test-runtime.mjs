import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source = fs.readFileSync(new URL('../Sources/Pagekeep/Resources/Runtime.js', import.meta.url), 'utf8');
function fixture(initial = {}) {
  let id = 0, now = 0;
  const timers = new Map(), frames = new Map(), events = new Map(), messages = [];
  const document = { readyState: 'complete', hidden: true, visibilityState: 'hidden', hasFocus: () => false, addEventListener() {} };
  const window = {
    setTimeout(callback, delay) { const key = ++id; timers.set(key, {callback, due: now + delay}); return key; },
    clearTimeout(key) { timers.delete(key); },
    requestAnimationFrame(callback) { const key = ++id; frames.set(key, callback); return key; },
    cancelAnimationFrame(key) { frames.delete(key); },
    addEventListener(name, fn) { events.set(name, fn); },
    webkit: { messageHandlers: { pagekeep: { postMessage(value) { messages.push(value); } } } }
  };
  const originalRAF = window.requestAnimationFrame;
  const context = vm.createContext({ window, document, crypto: {randomUUID: () => 'test-frame'}, performance: {now: () => now},
    setTimeout: window.setTimeout, clearTimeout: window.clearTimeout,
    requestAnimationFrame: window.requestAnimationFrame, cancelAnimationFrame: window.cancelAnimationFrame,
    console });
  vm.runInContext(source.replace('__CONFIG__', JSON.stringify({continuous:false,probe:false,...initial})), context);
  const configure = next => context.__pagekeepConfigure(next);
  function advance(ms) {
    const until = now + ms;
    while (now < until) {
      now = Math.min(until, now + 20);
      const snapshot = [...frames.values()]; frames.clear(); snapshot.forEach(callback => callback(now));
      for (const [key, item] of [...timers]) { if (item.due <= now && timers.delete(key)) item.callback(); }
    }
  }
  return { context, window, document, timers, frames, events, messages, originalRAF, configure, advance };
}
test('inactive probe does not schedule any work', () => { const f=fixture(); assert.equal(f.timers.size,0); assert.equal(f.frames.size,0); });
test('observation never replaces website animation APIs', () => { const f=fixture(); f.configure({continuous:true,probe:true}); assert.equal(f.window.requestAnimationFrame,f.originalRAF); });
test('real page visibility and focus are untouched', () => { const f=fixture(); f.configure({continuous:true}); assert.equal(f.document.hidden,true); assert.equal(f.document.visibilityState,'hidden'); assert.equal(f.document.hasFocus(),false); });
test('probe schedules one timer and one animation callback', () => { const f=fixture(); f.configure({probe:true}); assert.equal(f.timers.size,1); assert.equal(f.frames.size,1); });
test('repeated activation does not duplicate work', () => { const f=fixture(); for(let i=0;i<100;i++)f.configure({probe:true}); assert.equal(f.timers.size,1); assert.equal(f.frames.size,1); });
test('deactivation cancels pending work', () => { const f=fixture({probe:true}); f.configure({probe:false}); assert.equal(f.timers.size,0); assert.equal(f.frames.size,0); });
test('one hundred mode transitions preserve bounded work', () => { const f=fixture({probe:true}); for(let i=0;i<100;i++){f.configure({continuous:true});f.configure({continuous:false});} assert.equal(f.timers.size,1);assert.equal(f.frames.size,1); });
test('measurements use elapsed wall-clock time', () => { const f=fixture({probe:true}); f.advance(2100); const m=f.messages.find(m=>m.kind==='probe'); assert.ok(m); assert.ok(m.elapsed>=2); assert.ok(m.ticks>=19&&m.ticks<=21); assert.equal(m.realHidden,true); });
test('pagehide cancels the probe', () => { const f=fixture({probe:true}); f.events.get('pagehide')(); assert.equal(f.timers.size,0);assert.equal(f.frames.size,0); });
test('reported mode acknowledgement is not a speed claim', () => { const f=fixture();f.configure({continuous:true});const m=f.messages.at(-1);assert.equal(m.kind,'applied');assert.equal(m.observationOnly,true);assert.equal(m.continuous,true);assert.equal(m.fullSpeed,undefined); });
