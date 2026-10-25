// Phone control page for VSL Mixer.  Served by the Mac app (RemoteServer.swift),
// which documents the WebSocket protocol.  No build step: plain JS.
//
// Screens, chosen by the URL hash:
//   #               pick your mix
//   #aux/N          a musician's own aux: one fader per input plus the aux master
//   #board/mix/N    whole board (passcode): any output's faders, plus mutes
//   #board/ch/C/eq  one channel's EQ (or /comp for its compressor)
'use strict';

const CODE_KEY = 'vslmixer.code';
const LAST_AUX_KEY = 'vslmixer.lastAux';
const LAST_MIX_KEY = 'vslmixer.lastBoardMix';
const ECHO_MS = 700;   // ignore the mixer's echo of a control we just moved

let S = null;          // latest state from the mixer
let M = null;          // latest meters
let ws = null;
let connected = false;
let retryMs = 500;
let screen = null;     // {el, update(), meters()}
let screenKey = '';
let denied = false;
let unlocking = false;
const busy = new Map();      // control key -> time of last local change
const pending = new Map();   // control key -> message waiting to be sent
let flushQueued = false;

const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
  del(k) { try { localStorage.removeItem(k); } catch (e) {} },
};

// ---------------------------------------------------------------- helpers

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
  return el;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

// Fader positions mean what the mixer says they mean (S.taper breakpoints).
function dbAt(pos) {
  const t = S.taper;
  if (pos < t[0][0]) return -Infinity;
  for (let i = 1; i < t.length; i++) {
    if (pos <= t[i][0]) {
      const [p0, d0] = t[i - 1], [p1, d1] = t[i];
      return d0 + (pos - p0) / (p1 - p0) * (d1 - d0);
    }
  }
  return t[t.length - 1][1];
}

function posAt(db) {
  const t = S.taper;
  if (db < t[0][1]) return 0;
  for (let i = 1; i < t.length; i++) {
    if (db <= t[i][1]) {
      const [p0, d0] = t[i - 1], [p1, d1] = t[i];
      return p0 + (db - d0) / (d1 - d0) * (p1 - p0);
    }
  }
  return 1;
}

function fmtDb(d, digits = 1) {
  if (!isFinite(d)) return '−∞ dB';
  const sign = d > 0.05 ? '+' : d < -0.05 ? '−' : '';
  return sign + Math.abs(d).toFixed(digits) + ' dB';
}

function fmtHz(f) {
  return f >= 1000 ? (f / 1000).toFixed(f >= 10000 ? 0 : 1) + ' kHz' : Math.round(f) + ' Hz';
}

// One whole dB up or down; below the bottom of the scale is off.
function stepPos(pos, dir) {
  const d = dbAt(pos);
  const bottom = S.taper[0][1], top = S.taper[S.taper.length - 1][1];
  if (!isFinite(d)) return dir > 0 ? posAt(bottom) : 0;
  const next = dir > 0 ? Math.floor(d + 1e-6) + 1 : Math.ceil(d - 1e-6) - 1;
  if (next < bottom) return 0;
  return posAt(Math.min(top, next));
}

function meterFrac(db) { return clamp((db + 60) / 60, 0, 1); }

function setMeter(meterEl, db) {
  meterEl.firstChild.style.width = ((1 - meterFrac(db)) * 100).toFixed(1) + '%';
}

function meterEl() { return h('div', { class: 'meter', 'aria-hidden': 'true' }, h('div', { class: 'cover' })); }

function setColors(target, mix) {
  target.style.setProperty('--ground', S.mixes[mix].ground);
  target.style.setProperty('--ink', S.mixes[mix].ink);
}

// ---------------------------------------------------------------- talking to the mixer

function connect() {
  const port = (Number(location.port) || 80) + 1;
  ws = new WebSocket(`ws://${location.hostname}:${port}/`);
  ws.onopen = () => {
    connected = true;
    retryMs = 500;
    showOffline(false);
    hello();
  };
  ws.onclose = () => {
    const was = connected;
    connected = false;
    ws = null;
    if (S || was) showOffline(true);
    setTimeout(connect, retryMs);
    retryMs = Math.min(5000, retryMs * 2);
  };
  ws.onerror = () => {};
  ws.onmessage = (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch (err) { return; }
    if (msg.t === 'state') onState(msg);
    else if (msg.t === 'm') onMeters(msg);
    else if (msg.t === 'denied') onDenied();
  };
}

function send(msg) {
  if (ws && connected) ws.send(JSON.stringify(msg));
}

function hello() {
  const r = route();
  if (r.kind === 'aux') send({ t: 'hello', role: 'aux', mix: r.mix });
  else if ((r.kind === 'board' || r.kind === 'channel') && store.get(CODE_KEY)) {
    unlocking = !S || !S.board;
    send({ t: 'hello', role: 'board', code: store.get(CODE_KEY) });
  } else send({ t: 'hello', role: 'viewer' });
}

// Moves are sent at most once per frame per control, and the control is
// marked busy so the mixer's echo doesn't fight the finger.
function queue(key, msg) {
  busy.set(key, performance.now());
  pending.set(key, msg);
  if (!flushQueued) {
    flushQueued = true;
    requestAnimationFrame(() => {
      flushQueued = false;
      for (const m of pending.values()) send(m);
      pending.clear();
    });
  }
}

function onState(next) {
  const now = performance.now();
  if (S) {
    for (const [key, t] of busy) {
      if (now - t > ECHO_MS) { busy.delete(key); continue; }
      const [kind, a, b] = key.split(':').map((x, i) => i ? Number(x) : x);
      if (kind === 'send') next.mixes[a].sends[b] = S.mixes[a].sends[b];
      else if (kind === 'master') next.mixes[a].master = S.mixes[a].master;
      else if (kind === 'mute') next.inputs[a].muted = S.inputs[a].muted;
      else if (kind === 'fx' && next.inputs[a].fx && S.inputs[a].fx) next.inputs[a].fx = S.inputs[a].fx;
    }
  }
  const structureChanged = !S || S.board !== next.board;
  S = next;
  if (next.board) { denied = false; unlocking = false; }
  else if (unlocking && !denied) { /* still waiting on the passcode reply */ }
  if (structureChanged || !screen) render();
  else screen.update();
}

function onMeters(m) {
  M = m;
  if (screen && screen.meters) screen.meters();
}

function onDenied() {
  store.del(CODE_KEY);
  denied = true;
  unlocking = false;
  render();
}

function showOffline(on) {
  document.getElementById('offline').hidden = !on;
  document.body.classList.toggle('offline', on);
}

// ---------------------------------------------------------------- routing

function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean);
  if (parts[0] === 'aux') {
    const mix = Number(parts[1]);
    if (mix >= 1 && mix <= 6) return { kind: 'aux', mix };
  }
  if (parts[0] === 'board') {
    if (parts[1] === 'ch' && parts[2] != null) {
      return { kind: 'channel', ch: clamp(Number(parts[2]) || 0, 0, 7), tab: parts[3] === 'comp' ? 'comp' : 'eq' };
    }
    const mix = parts[1] === 'mix' ? Number(parts[2]) : Number(store.get(LAST_MIX_KEY));
    return { kind: 'board', mix: clamp(mix || 0, 0, 6) };
  }
  return { kind: 'landing' };
}

function render() {
  const app = document.getElementById('app');
  document.body.classList.remove('tinted');
  document.body.style.removeProperty('--ground');
  document.body.style.removeProperty('--ink');
  if (!S) {
    app.replaceChildren(h('p', { class: 'loading' }, 'Connecting to the mixer…'));
    screen = null;
    return;
  }
  const r = route();
  const needsBoard = r.kind === 'board' || r.kind === 'channel';
  if (needsBoard && !S.board) screen = unlocking ? waitingScreen() : passcodeScreen();
  else if (r.kind === 'aux') screen = auxScreen(r.mix);
  else if (r.kind === 'board') screen = boardScreen(r.mix);
  else if (r.kind === 'channel') screen = channelScreen(r.ch, r.tab);
  else screen = landingScreen();
  app.replaceChildren(screen.el);
  screen.update();
  if (screen.meters && M) screen.meters();
}

window.addEventListener('hashchange', () => {
  const r = route();
  const key = r.kind + (r.kind === 'aux' ? r.mix : '');
  render();
  if (key !== screenKey) hello();   // the mixer tailors what it sends to the screen
  screenKey = key;
});

// ---------------------------------------------------------------- controls

// Horizontal fader.  Dragging is relative to where the thumb was, so a stray
// touch never jumps a level.
function fader({ get, set, label, meter }) {
  const el = h('div', { class: 'fader', role: 'slider', tabindex: '0', 'aria-label': label },
    h('div', { class: 'line' }), h('div', { class: 'fill' }), meter, h('div', { class: 'thumb' }));
  let startPos = null, startX = 0;
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    startPos = get();
    startX = e.clientX;
    el.classList.add('active');
    wake();
  });
  el.addEventListener('pointermove', (e) => {
    if (startPos === null) return;
    const travel = Math.max(1, el.clientWidth - 40);
    set(clamp(startPos + (e.clientX - startX) / travel, 0, 1));
  });
  const end = () => { startPos = null; el.classList.remove('active'); };
  el.addEventListener('pointerup', end);
  el.addEventListener('pointercancel', end);
  el.addEventListener('keydown', (e) => {
    const dir = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[e.key];
    if (dir) { e.preventDefault(); set(stepPos(get(), dir)); }
  });
  return {
    el,
    draw() {
      const p = get();
      el.style.setProperty('--p', p.toFixed(4));
      el.setAttribute('aria-valuetext', fmtDb(dbAt(p)));
    },
  };
}

// A button that repeats while held, for nudging levels a dB at a time.
function stepButton(text, label, fn) {
  const b = h('button', { class: 'step', type: 'button', 'aria-label': label }, text);
  let delay = null, repeat = null;
  const stop = () => { clearTimeout(delay); clearInterval(repeat); delay = repeat = null; };
  b.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    wake();
    fn();
    stop();
    delay = setTimeout(() => { repeat = setInterval(fn, 110); }, 450);
  });
  b.addEventListener('pointerup', stop);
  b.addEventListener('pointerleave', stop);
  b.addEventListener('pointercancel', stop);
  b.addEventListener('click', (e) => { if (e.detail === 0) fn(); });   // keyboard
  b.addEventListener('contextmenu', (e) => e.preventDefault());       // long press on Android
  return b;
}

// One input's level in one output: name, dB, −, fader, +, input meter.
function sendRow(mix, ch, board) {
  const key = `send:${mix}:${ch}`;
  const get = () => S.mixes[mix].sends[ch];
  const set = (pos) => {
    S.mixes[mix].sends[ch] = pos;
    queue(key, { t: 'send', mix, ch, pos });
    update();
  };
  const name = board ? h('a', { class: 'name', href: `#board/ch/${ch}/eq` }) : h('span', { class: 'name' });
  const db = h('span', { class: 'db' });
  const tag = h('span', { class: 'tag' }, 'Muted');
  const meter = meterEl();
  const f = fader({ get, set, label: '', meter });
  const mute = board ? h('button', {
    class: 'mutebtn', type: 'button',
    onclick: () => {
      S.inputs[ch].muted = !S.inputs[ch].muted;
      queue(`mute:${ch}`, { t: 'mute', ch, on: S.inputs[ch].muted });
      screen.update();   // mute shows in every row of this input
    },
  }) : null;
  const el = h('div', { class: 'row' },
    h('div', { class: 'rowhead' }, name, board ? null : tag, db, mute),
    h('div', { class: 'ctl' },
      stepButton('−', 'Down 1 dB', () => set(stepPos(get(), -1))),
      f.el,
      stepButton('+', 'Up 1 dB', () => set(stepPos(get(), 1)))));

  function update() {
    const input = S.inputs[ch];
    name.replaceChildren(h('span', { class: 'num' }, String(ch + 1)), input.name);
    db.textContent = fmtDb(dbAt(get()));
    tag.hidden = !input.muted;
    el.classList.toggle('dim', input.muted);
    f.el.setAttribute('aria-label', `${input.name} in ${S.mixes[mix].name}`);
    f.draw();
    if (mute) {
      mute.textContent = input.muted ? 'Muted' : 'Mute';
      mute.setAttribute('aria-pressed', String(input.muted));
    }
  }
  return { el, update, meters() { setMeter(meter, M.in[ch]); } };
}

function masterRow(mix) {
  const key = `master:${mix}`;
  const get = () => S.mixes[mix].master;
  const set = (pos) => {
    S.mixes[mix].master = pos;
    queue(key, { t: 'master', mix, pos });
    update();
  };
  const name = h('span', { class: 'name' });
  const db = h('span', { class: 'db' });
  const meter = meterEl();
  const f = fader({ get, set, label: '', meter });
  const el = h('div', { class: 'master' },
    h('div', { class: 'rowhead' }, name, db),
    h('div', { class: 'ctl' },
      stepButton('−', 'Output down 1 dB', () => set(stepPos(get(), -1))),
      f.el,
      stepButton('+', 'Output up 1 dB', () => set(stepPos(get(), 1)))));
  function update() {
    name.textContent = S.mixes[mix].name;
    db.textContent = fmtDb(dbAt(get()));
    f.el.setAttribute('aria-label', `${S.mixes[mix].name} level`);
    f.draw();
  }
  return { el, update, meters() { setMeter(meter, M.mix[mix]); } };
}

// ---------------------------------------------------------------- screens

function landingScreen() {
  const grid = h('div', { class: 'mixgrid' });
  const el = h('div', { style: 'display:contents' },
    h('header', { class: 'bar' }, h('h1', {}, 'VSL Mixer'), h('span', { class: 'dot', 'aria-hidden': 'true' })),
    h('main', { class: 'landing' },
      h('p', { class: 'lead' }, 'Which mix is yours?'),
      grid,
      h('a', { class: 'boardbtn', href: '#board' }, 'Whole board', h('span', {}, 'needs passcode'))));
  return {
    el,
    update() {
      const last = Number(store.get(LAST_AUX_KEY));
      grid.replaceChildren(...S.mixes.slice(1).map((m, i) => {
        const a = h('a', { class: 'mixbtn', href: `#aux/${i + 1}` },
          h('b', {}, m.name),
          // On the right of the outputs line, so marking a mix doesn't move anything.
          h('div', { class: 'sub' }, h('span', {}, m.outs), last === i + 1 ? h('em', {}, 'Last used') : null));
        a.style.setProperty('--ground', m.ground);
        a.style.setProperty('--ink', m.ink);
        return a;
      }));
    },
  };
}

function auxScreen(mix) {
  store.set(LAST_AUX_KEY, String(mix));
  document.body.classList.add('tinted');
  setColors(document.body, mix);
  const title = h('div', { class: 'title' }, h('b'), h('span'));
  const rows = [...Array(S.inputs.length).keys()].map((ch) => sendRow(mix, ch, false));
  const master = masterRow(mix);
  const el = h('div', { style: 'display:contents' },
    h('header', { class: 'bar' },
      h('a', { class: 'back', href: '#', 'aria-label': 'Choose a different mix' }, '‹'),
      title,
      h('span', { class: 'dot', 'aria-hidden': 'true' })),
    h('div', { class: 'list' }, rows.map((r) => r.el)),
    master.el);
  return {
    el,
    update() {
      setColors(document.body, mix);
      title.firstChild.textContent = S.mixes[mix].name;
      title.lastChild.textContent = `${S.mixes[mix].outs} · your mix`;
      rows.forEach((r) => r.update());
      master.update();
    },
    meters() { rows.forEach((r) => r.meters()); master.meters(); },
  };
}

function boardScreen(mix) {
  store.set(LAST_MIX_KEY, String(mix));
  const chips = h('nav', { class: 'chips', 'aria-label': 'Outputs' });
  const list = h('div', { class: 'list' });
  setColors(list, mix);
  const rows = [...Array(S.inputs.length).keys()].map((ch) => sendRow(mix, ch, true));
  list.append(...rows.map((r) => r.el));
  const master = masterRow(mix);
  setColors(master.el, mix);
  const el = h('div', { style: 'display:contents' },
    h('header', { class: 'bar' },
      h('a', { class: 'back', href: '#', 'aria-label': 'Leave the whole board' }, '‹'),
      h('h1', {}, 'Whole board'),
      h('span', { class: 'dot', 'aria-hidden': 'true' })),
    chips, list, master.el);
  return {
    el,
    update() {
      chips.replaceChildren(...S.mixes.map((m, i) => {
        const a = h('a', { class: 'chip', href: `#board/mix/${i}`, 'aria-current': i === mix ? 'page' : null },
          h('b', {}, m.name), h('span', {}, m.outs));
        a.style.setProperty('--chip-ground', m.ground);
        a.style.setProperty('--chip-ink', m.ink);
        return a;
      }));
      const current = chips.children[mix];
      if (current && current.scrollIntoView) current.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      rows.forEach((r) => r.update());
      master.update();
    },
    meters() { rows.forEach((r) => r.meters()); master.meters(); },
  };
}

function passcodeScreen() {
  const input = h('input', {
    type: 'tel', inputmode: 'numeric', autocomplete: 'off', maxlength: '6',
    'aria-label': 'Passcode', placeholder: '····',
  });
  const submit = (e) => {
    e.preventDefault();
    const code = input.value.trim();
    if (!code) return;
    store.set(CODE_KEY, code);
    denied = false;
    unlocking = true;
    render();
    hello();
  };
  const el = h('div', { style: 'display:contents' },
    h('header', { class: 'bar' },
      h('a', { class: 'back', href: '#', 'aria-label': 'Back' }, '‹'),
      h('h1', {}, 'Whole board'),
      h('span', { class: 'dot', 'aria-hidden': 'true' })),
    h('form', { class: 'passcode', onsubmit: submit },
      h('p', {}, 'Enter the passcode shown in the mixer’s Phones window.'),
      denied ? h('p', { class: 'error' }, 'That passcode didn’t work.') : null,
      input,
      h('button', { class: 'primary', type: 'submit' }, 'Unlock')));
  setTimeout(() => input.focus(), 50);
  return { el, update() {} };
}

function waitingScreen() {
  return { el: h('p', { class: 'loading' }, 'Unlocking…'), update() {} };
}

function channelScreen(ch, tab) {
  const back = Number(store.get(LAST_MIX_KEY)) || 0;
  const title = h('div', { class: 'title' }, h('b'), h('span'));
  const mute = h('button', {
    class: 'mutebtn', type: 'button',
    onclick: () => {
      S.inputs[ch].muted = !S.inputs[ch].muted;
      queue(`mute:${ch}`, { t: 'mute', ch, on: S.inputs[ch].muted });
      update();
    },
  });
  const inMeter = meterEl();
  const editor = tab === 'eq' ? eqEditor(ch) : compEditor(ch);
  const el = h('div', { style: 'display:contents' },
    h('header', { class: 'bar' },
      h('a', { class: 'back', href: `#board/mix/${back}`, 'aria-label': 'Back to the faders' }, '‹'),
      title, mute),
    h('div', { class: 'chan' },
      h('div', { class: 'inmeter' }, 'Input', inMeter),
      h('nav', { class: 'tabs' },
        h('a', { href: `#board/ch/${ch}/eq`, 'aria-current': tab === 'eq' ? 'page' : null }, 'EQ'),
        h('a', { href: `#board/ch/${ch}/comp`, 'aria-current': tab === 'comp' ? 'page' : null }, 'Compressor')),
      editor.el));
  function update() {
    const input = S.inputs[ch];
    title.firstChild.textContent = input.name;
    title.lastChild.textContent = `In ${ch + 1}`;
    mute.textContent = input.muted ? 'Muted' : 'Mute';
    mute.setAttribute('aria-pressed', String(input.muted));
    editor.update();
  }
  return {
    el,
    update,
    meters() { setMeter(inMeter, M.in[ch]); if (editor.meters) editor.meters(); },
  };
}

// ---------------------------------------------------------------- processing editors

function setFx(ch, changes) {
  Object.assign(S.inputs[ch].fx, changes);
  const key = `fx:${ch}`;
  const prev = pending.get(key);
  queue(key, { t: 'channel', ch, set: Object.assign({}, prev ? prev.set : {}, changes) });
  if (screen) screen.update();
}

function resetFx(ch, what) {
  busy.delete(`fx:${ch}`);
  pending.delete(`fx:${ch}`);
  send({ t: 'reset', ch, what });
}

// Same filter design as the engine (RBJ biquads at 48 kHz), so the curve is
// exactly what's running.
const FS = 48000;
function biquad(type, f, db, q) {
  const w = 2 * Math.PI * clamp(f, 10, 0.45 * FS) / FS, c = Math.cos(w), s = Math.sin(w);
  const A = Math.pow(10, db / 40);
  let b0, b1, b2, a0, a1, a2;
  if (type === 'hp') {
    const al = s / (2 * Math.SQRT1_2);
    [b0, b1, b2, a0, a1, a2] = [(1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al];
  } else if (type === 'peak') {
    const al = s / (2 * Math.max(0.1, q));
    [b0, b1, b2, a0, a1, a2] = [1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A];
  } else {
    const ta = 2 * Math.sqrt(A) * (s / 2 * Math.SQRT2);
    if (type === 'high') {
      [b0, b1, b2, a0, a1, a2] = [A * ((A + 1) + (A - 1) * c + ta), -2 * A * ((A - 1) + (A + 1) * c),
        A * ((A + 1) + (A - 1) * c - ta), (A + 1) - (A - 1) * c + ta, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - ta];
    } else {
      [b0, b1, b2, a0, a1, a2] = [A * ((A + 1) - (A - 1) * c + ta), 2 * A * ((A - 1) - (A + 1) * c),
        A * ((A + 1) - (A - 1) * c - ta), (A + 1) + (A - 1) * c + ta, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - ta];
    }
  }
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}

function responseDb([b0, b1, b2, a1, a2], f) {
  const w = 2 * Math.PI * f / FS;
  const c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
  const nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
  const dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
  return 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

function eqFilters(fx) {
  return {
    hpf: fx.hpfHz > 20.5 ? biquad('hp', fx.hpfHz) : null,
    bands: (fx.lowDb || fx.midDb || fx.highDb)
      ? [biquad('low', fx.lowHz, fx.lowDb), biquad('peak', fx.midHz, fx.midDb, fx.midQ), biquad('high', fx.highHz, fx.highDb)]
      : [],
  };
}

function eqDb(filters, f) {
  let d = filters.hpf ? responseDb(filters.hpf, f) : 0;
  for (const b of filters.bands) d += responseDb(b, f);
  return d;
}

function compOut(fx, input) {
  const over = input - fx.thresholdDb;
  return (over > 0 ? fx.thresholdDb + over / fx.ratio : input) + fx.makeupDb;
}

// Canvas sized for the screen's pixel density; returns a 2D context in CSS px.
function prepCanvas(canvas, cssHeight) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth || 300;
  canvas.style.height = cssHeight + 'px';
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(cssHeight * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(cssHeight * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, cssHeight);
  return { ctx, w, h: cssHeight };
}

function nearest(points, x, y, within) {
  let best = null, bestD = within;
  for (const p of points) {
    const d = Math.hypot(p.x - x, p.y - y);
    if (d < bestD) { best = p; bestD = d; }
  }
  return best;
}

const BANDS = [
  { k: 'hpf', name: 'High-pass', color: '#FFAE6B', f: 'hpfHz', g: null, lo: 20, hi: 400 },
  { k: 'low', name: 'Low shelf', color: '#7FB2FF', f: 'lowHz', g: 'lowDb', lo: 30, hi: 500 },
  { k: 'mid', name: 'Mid', color: '#5BD495', f: 'midHz', g: 'midDb', lo: 150, hi: 8000 },
  { k: 'high', name: 'High shelf', color: '#FF86B0', f: 'highHz', g: 'highDb', lo: 1500, hi: 18000 },
];

function eqEditor(ch) {
  let sel = BANDS[2], drag = null, grab = [0, 0], geom = null;
  const canvas = h('canvas', { class: 'graph', role: 'img', 'aria-label': 'EQ curve' });
  const info = h('div', { class: 'info' });
  const bandBtns = BANDS.map((b) => {
    const btn = h('button', { type: 'button', onclick: () => { sel = b; update(); } }, b.name);
    btn.style.setProperty('--band', b.color);
    return btn;
  });
  const q = h('span', { style: 'min-width:52px;text-align:center;font-variant-numeric:tabular-nums' });
  const setQ = (v) => setFx(ch, { midQ: Math.round(clamp(v, 0.3, 5) * 10) / 10 });
  const qRow = h('div', { class: 'qrow' },
    h('span', { class: 'hint' }, 'Width'),
    stepButton('−', 'Narrower', () => setQ(S.inputs[ch].fx.midQ + 0.2)),
    q,
    stepButton('+', 'Wider', () => setQ(S.inputs[ch].fx.midQ - 0.2)));
  const reset = h('button', { class: 'reset', type: 'button', onclick: () => resetFx(ch, 'eq') }, 'Reset to flat');
  const el = h('div', { style: 'display:contents' },
    h('p', { class: 'hint' }, 'Drag the points. The high-pass is off at the far left.'),
    canvas, info, h('div', { class: 'bands' }, bandBtns), h('div', { class: 'controls' }, qRow, reset));

  const PAD = 14;   // keeps handles at the ends fully on screen
  const X = (f) => PAD + (geom.w - 2 * PAD) * Math.log(f / 20) / Math.log(1000);
  const F = (x) => 20 * Math.pow(1000, (x - PAD) / (geom.w - 2 * PAD));
  const Y = (d) => geom.h / 2 - d / 18 * geom.h / 2;
  const D = (y) => (geom.h / 2 - y) / (geom.h / 2) * 18;

  function handles(fx, filters) {
    return BANDS.map((b) => {
      const f = fx[b.f];
      const g = b.g ? fx[b.g] : Math.max(-18, eqDb(filters, f));
      return { b, x: X(f), y: clamp(Y(g), 2, geom.h - 2) };
    });
  }

  canvas.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
    const fx = S.inputs[ch].fx;
    const hit = nearest(handles(fx, eqFilters(fx)), x, y, 44);
    if (!hit) return;
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    drag = hit.b; sel = hit.b;
    grab = [hit.x - x, hit.y - y];
    wake();
    update();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const r = canvas.getBoundingClientRect();
    const x = e.clientX - r.left + grab[0], y = e.clientY - r.top + grab[1];
    const changes = { [drag.f]: clamp(F(x), drag.lo, drag.hi) };
    if (drag.g) changes[drag.g] = clamp(D(y), -18, 18);
    setFx(ch, changes);
  });
  const end = () => { drag = null; };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);

  function update() {
    const fx = S.inputs[ch].fx;
    const height = Math.round(clamp(window.innerHeight * 0.5, 240, 460));
    const { ctx, w, h: ht } = prepCanvas(canvas, height);
    geom = { w, h: ht };
    const filters = eqFilters(fx);

    ctx.lineWidth = 1;
    for (const f of [100, 1000, 10000]) {
      ctx.strokeStyle = 'rgba(255,255,255,0.10)';
      ctx.beginPath(); ctx.moveTo(X(f), 0); ctx.lineTo(X(f), ht); ctx.stroke();
    }
    for (const d of [-12, -6, 6, 12]) {
      ctx.strokeStyle = 'rgba(255,255,255,0.07)';
      ctx.beginPath(); ctx.moveTo(0, Y(d)); ctx.lineTo(w, Y(d)); ctx.stroke();
    }
    ctx.strokeStyle = 'rgba(255,255,255,0.22)';
    ctx.beginPath(); ctx.moveTo(0, ht / 2); ctx.lineTo(w, ht / 2); ctx.stroke();
    ctx.fillStyle = 'rgba(255,255,255,0.6)';
    ctx.font = '11px system-ui, sans-serif';
    ctx.textBaseline = 'alphabetic';
    for (const [t, f] of [['100', 100], ['1k', 1000], ['10k', 10000]]) ctx.fillText(t, X(f) + 3, ht - 6);
    ctx.fillText('+18 dB', 6, 14);
    ctx.fillText('−18 dB', 6, ht - 20);

    ctx.beginPath();
    const n = Math.max(2, Math.round(w / 3));
    for (let i = 0; i <= n; i++) {
      const x = w * i / n, y = clamp(Y(eqDb(filters, F(x))), 1, ht - 1);
      if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
    }
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 2.5;
    ctx.stroke();
    ctx.lineTo(w, ht / 2); ctx.lineTo(0, ht / 2); ctx.closePath();
    ctx.fillStyle = 'rgba(255,255,255,0.07)';
    ctx.fill();

    for (const p of handles(fx, filters)) {
      const on = p.b.k !== 'hpf' || fx.hpfHz > 20.5;
      const r = p.b === sel ? 13 : 10;
      ctx.beginPath(); ctx.arc(p.x, p.y, r, 0, 2 * Math.PI);
      ctx.fillStyle = on ? p.b.color : '#55585E';
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = p.b === sel ? '#FFFFFF' : '#0B0C0E';
      ctx.stroke();
    }

    const f = fx[sel.f];
    info.textContent = sel.g ? `${sel.name} · ${fmtHz(f)} · ${fmtDb(fx[sel.g])}`
      : fx.hpfHz > 20.5 ? `${sel.name} · ${fmtHz(f)} · 12 dB/octave` : `${sel.name} · off`;
    info.style.color = sel.color;
    bandBtns.forEach((btn, i) => btn.setAttribute('aria-pressed', String(BANDS[i] === sel)));
    qRow.hidden = sel.k !== 'mid';
    q.textContent = 'Q ' + fx.midQ.toFixed(1);
    reset.disabled = !(fx.hpfHz > 20.5 || fx.lowDb || fx.midDb || fx.highDb);
    canvas.setAttribute('aria-label', 'EQ curve. ' + info.textContent);
  }
  return { el, update };
}

function compEditor(ch) {
  let drag = null, grab = [0, 0], side = 300;
  const canvas = h('canvas', { class: 'graph', role: 'img', 'aria-label': 'Compressor curve' });
  const thr = h('b'), ratio = h('b'), makeup = h('b');
  const grBar = h('div'), grText = h('b');
  const reset = h('button', { class: 'reset', type: 'button', onclick: () => resetFx(ch, 'comp') }, 'Reset to linear');
  const logSlider = (label, key, lo, hi, fmt) => {
    const value = h('b');
    const input = h('input', { type: 'range', min: '0', max: '1000', 'aria-label': label });
    input.addEventListener('input', () => setFx(ch, { [key]: lo * Math.pow(hi / lo, input.value / 1000) }));
    return {
      el: h('div', { class: 'slider' }, h('label', {}, label, value), input),
      update() {
        const v = S.inputs[ch].fx[key];
        value.textContent = fmt(v);
        if (document.activeElement !== input) input.value = String(Math.round(Math.log(v / lo) / Math.log(hi / lo) * 1000));
      },
    };
  };
  const attack = logSlider('Attack', 'attackMs', 0.2, 100, (v) => (v < 10 ? v.toFixed(1) : v.toFixed(0)) + ' ms');
  const release = logSlider('Release', 'releaseMs', 20, 1000, (v) => v.toFixed(0) + ' ms');
  const wrap = h('div', { style: 'width:100%' }, canvas);   // measures the width available
  const el = h('div', { style: 'display:contents' },
    h('p', { class: 'hint' }, 'Drag the knee for threshold (sideways) and makeup gain (up). Drag the right-hand point for ratio. Green is the live input.'),
    wrap,
    h('div', { class: 'stats' },
      h('div', {}, h('span', {}, 'Threshold'), thr),
      h('div', {}, h('span', {}, 'Ratio'), ratio),
      h('div', {}, h('span', {}, 'Makeup'), makeup)),
    h('div', { class: 'gr' }, 'Reduction', h('div', { class: 'grbar' }, grBar), grText),
    attack.el, release.el,
    h('div', { class: 'controls' }, h('span'), reset));

  const PAD = 14;   // keeps handles at the edges fully on screen
  const X = (d) => PAD + (d + 60) / 60 * (side - 2 * PAD);
  const IN = (x) => (x - PAD) / (side - 2 * PAD) * 60 - 60;
  const Y = (d) => PAD + (12 - d) / 72 * (side - 2 * PAD);
  const OUT = (y) => 12 - (y - PAD) / (side - 2 * PAD) * 72;

  function handles(fx) {
    return [{ k: 'knee', x: X(fx.thresholdDb), y: Y(fx.thresholdDb + fx.makeupDb) },
            { k: 'end', x: X(0), y: Y(compOut(fx, 0)) }];
  }

  canvas.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
    const hit = nearest(handles(S.inputs[ch].fx), x, y, 44);
    if (!hit) return;
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    drag = hit.k;
    grab = [hit.x - x, hit.y - y];
    wake();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const r = canvas.getBoundingClientRect();
    const input = IN(e.clientX - r.left + grab[0]), output = OUT(e.clientY - r.top + grab[1]);
    const fx = S.inputs[ch].fx;
    if (drag === 'knee') {
      const t = clamp(input, -50, -2);
      setFx(ch, { thresholdDb: t, makeupDb: clamp(output - t, 0, 20) });
    } else {
      const rise = output - fx.makeupDb - fx.thresholdDb;
      setFx(ch, { ratio: rise <= 0.5 ? 20 : clamp(-fx.thresholdDb / rise, 1, 20) });
    }
  });
  const end = () => { drag = null; };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);

  function draw() {
    const fx = S.inputs[ch].fx;
    side = Math.min(wrap.clientWidth || 300, Math.round(window.innerHeight * 0.45));
    canvas.style.width = side + 'px';
    canvas.style.margin = '0 auto';
    const { ctx } = prepCanvas(canvas, side);
    ctx.lineWidth = 1;
    for (const v of [-48, -36, -24, -12]) {
      ctx.strokeStyle = 'rgba(255,255,255,0.07)';
      ctx.beginPath(); ctx.moveTo(X(v), 0); ctx.lineTo(X(v), side); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(0, Y(v)); ctx.lineTo(side, Y(v)); ctx.stroke();
    }
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.beginPath(); ctx.moveTo(0, Y(0)); ctx.lineTo(side, Y(0)); ctx.stroke();
    ctx.setLineDash([5, 5]);
    ctx.strokeStyle = 'rgba(255,255,255,0.3)';
    ctx.beginPath(); ctx.moveTo(X(-60), Y(-60)); ctx.lineTo(X(0), Y(0)); ctx.stroke();
    ctx.setLineDash([]);

    ctx.beginPath();
    ctx.moveTo(X(-60), Y(compOut(fx, -60)));
    ctx.lineTo(X(fx.thresholdDb), Y(compOut(fx, fx.thresholdDb)));
    ctx.lineTo(X(0), Y(compOut(fx, 0)));
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 3;
    ctx.stroke();

    if (M) {
      const input = clamp(M.in[ch], -60, 0);
      ctx.beginPath();
      ctx.arc(X(input), Math.max(0, Y(compOut(fx, input))), 6, 0, 2 * Math.PI);
      ctx.fillStyle = '#3DD68C';
      ctx.fill();
    }
    for (const p of handles(fx)) {
      ctx.beginPath(); ctx.arc(p.x, p.y, 13, 0, 2 * Math.PI);
      ctx.fillStyle = '#FFFFFF'; ctx.fill();
      ctx.lineWidth = 2; ctx.strokeStyle = '#0B0C0E'; ctx.stroke();
    }
    ctx.fillStyle = 'rgba(255,255,255,0.6)';
    ctx.font = '11px system-ui, sans-serif';
    ctx.fillText('−60 in', PAD + 4, side - 4);
    ctx.fillText('0 in', side - PAD - 24, side - 4);
    ctx.fillText('+12 out', PAD + 4, 12);
  }

  function update() {
    const fx = S.inputs[ch].fx;
    draw();
    thr.textContent = fx.thresholdDb.toFixed(1) + ' dB';
    ratio.textContent = fx.ratio >= 20 ? '20:1' : fx.ratio.toFixed(1) + ':1';
    makeup.textContent = fmtDb(fx.makeupDb);
    attack.update();
    release.update();
    reset.disabled = !(fx.ratio > 1.001 || Math.abs(fx.makeupDb) > 0.001);
    canvas.setAttribute('aria-label', `Compressor: threshold ${thr.textContent}, ratio ${ratio.textContent}, makeup ${makeup.textContent}`);
  }

  return {
    el,
    update,
    meters() {
      const gr = M.gr[ch];
      grBar.style.width = clamp(gr / 20 * 100, 0, 100).toFixed(0) + '%';
      grText.textContent = gr > 0.05 ? '−' + gr.toFixed(1) + ' dB' : '0.0 dB';
      draw();
    },
  };
}

// ---------------------------------------------------------------- startup

// Keep the screen on while someone is mixing, where the browser allows it
// (it needs a secure page, so this mostly won't apply over plain HTTP).
let wakeLock = null;
function wake() {
  if (wakeLock || !('wakeLock' in navigator)) return;
  navigator.wakeLock.request('screen').then((l) => {
    wakeLock = l;
    l.addEventListener('release', () => { wakeLock = null; });
  }).catch(() => {});
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && !ws) connect();
});
window.addEventListener('resize', () => { if (screen) screen.update(); });

screenKey = (() => { const r = route(); return r.kind + (r.kind === 'aux' ? r.mix : ''); })();
connect();
