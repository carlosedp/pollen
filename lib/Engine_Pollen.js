// Engine_Pollen.js: Engine_Pollen.sc for the browser, used by tools/norns-web.
// norns ignores this file.
//
// The same graph as the engine's three SynthDefs, in one AudioWorklet (the reel, the grains
// and the output stage share the buffers), with the reverb on MiVerb, the same mi-UGen the
// engine plays, compiled to WebAssembly (lib/Engine_Pollen/, from norns-mi-UGens):
//
//   input -> writer -> reel -> grains -> filter, drive, media -> + dry, static -> level -> limiter -> out
//                                                    \-> send -> MiVerb ------/
//
// Keep it in step with the engine: a SynthDef change goes here too. The filters are
// SuperCollider's own (RLPF, RHPF, BPF, LPF), the lags SuperCollider's Lag (60 dB in t),
// applied once per 128-sample block.
//
// Polls: amp_in, amp_reel and head, as the engine's addPoll gives them, from the worklet.
//
// Until norns-web plays the radio, the input is a small made-up broadcast (demo() below),
// standing in for whatever reaches a norns' input.
(() => {
const BASE = document.currentScript.src.replace(/\.js(\?.*)?$/, "/");

// every parameter of the engine, at the SynthDefs' defaults
const DEFAULTS = {
  adc: 1, freeze: 0, fb: 0,
  density: 8, jitter: 0.3, size: 0.15, position: 0.5, pos_spread: 0.05, pitch: 0, pitch_spread: 0,
  reverse: 0, spread: 0.5, env: 0, amp: 0.5,
  mix: 0.7, level: 1, ftype: 0, cutoff: 2000, res: 0.2, drive: 0, media: 0,
  send: 0.3, vsize: 0.6, vfreeze: 0, static: 0,
};

const PROCESSOR = `
const LAGS = { adc: 0.1, fb: 0.2, amp: 0.1, spread: 0.1, cutoff: 0.1, res: 0.1, drive: 0.1,
  send: 0.1, mix: 0.1, static: 0.05 };
const BLOCK = 128, MAX_GRAINS = 32, TAU = Math.PI * 2;
const softclip = x => Math.abs(x) <= 0.5 ? x : (Math.abs(x) - 0.25) / x;
const rand = () => Math.random();

class Pollen extends AudioWorkletProcessor {
  constructor(o) {
    super();
    const { params, reel } = o.processorOptions;
    this.p = { ...params };                 // targets
    this.l = { ...params };                 // lagged values
    this.newReel(reel);
    this.grains = [];
    for (let i = 0; i < MAX_GRAINS; i++) this.grains.push({ on: false });
    this.imp = 0; this.backL = 0; this.backR = 0;
    // filter states, as plain numbers (no arrays on the audio thread)
    this.hxL = 0; this.hyL = 0; this.hxR = 0; this.hyR = 0;
    this.fL1 = 0; this.fL2 = 0; this.fR1 = 0; this.fR2 = 0;
    this.lL1 = 0; this.lL2 = 0; this.lR1 = 0; this.lR2 = 0;
    this.latch = [0, 0, 0];                // phase, held L, held R
    this.tape = [new Float32Array(Math.ceil(sampleRate * 0.05)), new Float32Array(Math.ceil(sampleRate * 0.05))];
    this.tw = 0; this.osc = 0;
    this.noise2 = { a: 0, b: rand() * 2 - 1, c: rand() * 2 - 1, ph: 1 };
    this.pink = [0, 0, 0, 0, 0, 0, 0];
    // Amplitude.kr followers (attack, release: -40 dB in t) for the polls, reported ~60 times a second
    const amp = (a, r) => ({ y: 0, ca: Math.exp(Math.log(0.01) / (a * sampleRate)), cr: Math.exp(Math.log(0.01) / (r * sampleRate)) });
    this.ampIn = amp(0.05, 0.5); this.ampReel = amp(0.01, 0.1); this.report = 0;
    this.st = { b1: 0, b2: 0, f1: this.lfn1(0.7), f2: this.lfn1(0.3), sine: 0 };
    this.port.onmessage = e => {
      const m = e.data;
      if (m.set) this.p[m.set[0]] = m.set[1];
      if (m.reel) this.newReel(m.reel);
      if (m.clear) { this.bufL.fill(0); this.bufR.fill(0); }
    };
  }
  newReel(seconds) {
    const n = Math.max(1, Math.round(Math.min(60, Math.max(1, seconds)) * sampleRate));
    this.bufL = new Float32Array(n); this.bufR = new Float32Array(n);
    this.head = (this.head || 0) % n;
  }
  // LFNoise1: a straight line to a new random value, freq times a second
  lfn1(freq) { return { freq, from: rand() * 2 - 1, to: rand() * 2 - 1, ph: 0 }; }
  stepLfn1(n) {
    n.ph += n.freq / sampleRate;
    if (n.ph >= 1) { n.ph -= 1; n.from = n.to; n.to = rand() * 2 - 1; }
    return n.from + (n.to - n.from) * n.ph;
  }
  // LFNoise2 (near enough): a smooth curve through new random values, 0.5 a second
  stepNoise2() {
    const n = this.noise2;
    n.ph += 0.5 / sampleRate;
    if (n.ph >= 1) { n.ph -= 1; n.a = n.b; n.b = n.c; n.c = rand() * 2 - 1; }
    const x = n.ph, m1 = (n.a + n.b) / 2, m2 = (n.b + n.c) / 2;
    return (1 - x) * (1 - x) * m1 + 2 * (1 - x) * x * n.b + x * x * m2;
  }
  envAt(kind, x) {
    if (kind === 1) { // Env.perc(0.04, 0.96, 1, -4)
      if (x < 0.04) return x / 0.04;
      const t = (x - 0.04) / 0.96;
      return 1 - (1 - Math.exp(-4 * t)) / (1 - Math.exp(-4));
    }
    if (kind === 2) { // Env.linen(0.03, 0.94, 0.03, 1, \\sin)
      if (x < 0.03) return Math.sin(Math.PI / 2 * x / 0.03);
      if (x > 0.97) return Math.sin(Math.PI / 2 * (1 - x) / 0.03);
      return 1;
    }
    return 0.5 - 0.5 * Math.cos(TAU * x); // GrainBuf's Hann
  }
  startGrain(sr, frames) {
    const p = this.p, g = this.grains.find(g => !g.on);
    if (!g) return;
    const dur = Math.min(4, Math.max(0.005, p.size));
    const dir = rand() < p.reverse ? -1 : 1;
    const rate = Math.pow(2, (p.pitch + p.pitch_spread * (rand() * 2 - 1)) / 12) * dir;
    const run = p.freeze < 0.5 ? 1 : 0;
    const minAge = Math.max(0, Math.max(rate, 0) - run) * dur + 0.005;
    const age = Math.max(minAge, p.position + p.pos_spread * (frames / sr) * rand());
    let pos = (this.head - age * sr) % frames; if (pos < 0) pos += frames;
    const pan = (rand() * 2 - 1) * this.l.spread, a = (pan + 1) * Math.PI / 4;
    Object.assign(g, { on: true, pos, rate, i: 0, n: Math.max(1, Math.round(dur * sr)), env: p.env | 0,
      gl: Math.min(1, Math.SQRT2 * Math.cos(a)), gr: Math.min(1, Math.SQRT2 * Math.sin(a)) });
  }
  process(inputs, outputs) {
    const input = inputs[0], out = outputs[0], sendOut = outputs[1];
    const n = out[0].length, sr = sampleRate, p = this.p, l = this.l;
    // the block's lagged controls (Lag: 60 dB in t)
    for (const k in p) {
      const t = LAGS[k];
      if (!t) { l[k] = p[k]; continue; }
      const b = Math.exp(Math.log(0.001) / (t * sr / BLOCK));
      l[k] = p[k] + (l[k] - p[k]) * b;
    }
    const inL = input && input[0], inR = input && (input[1] || input[0]);
    const bufL = this.bufL, bufR = this.bufR, frames = bufL.length;
    const run = p.freeze < 0.5;
    const dur = Math.min(4, Math.max(0.005, p.size));
    const dens = Math.min(Math.min(200, Math.max(0.1, p.density)), 28 / dur);
    const jitter = p.jitter;
    // the filter's coefficients, as RLPF / RHPF / BPF compute them
    const f = Math.min(20000, Math.max(20, l.cutoff)), rq = 1 - Math.min(0.95, Math.max(0, l.res));
    const ftype = p.ftype | 0, pf = f * TAU / sr;
    let fa0 = 0, fb1 = 0, fb2 = 0;
    if (ftype === 1 || ftype === 2) {
      const D = Math.tan(pf * Math.max(0.001, rq) * 0.5), C = (1 - D) / (1 + D), cs = Math.cos(pf);
      fb1 = (1 + C) * cs; fb2 = -C; fa0 = ftype === 1 ? (1 + C - fb1) * 0.25 : (1 + C + fb1) * 0.25;
    } else if (ftype === 3) {
      const C = 1 / Math.tan(rq * pf * 0.5), D = 2 * Math.cos(pf);
      fa0 = 1 / (1 + C); fb1 = C * D * fa0; fb2 = (1 - C) * fa0;
    }
    const gdrive = 1 + l.drive * 8, tg = Math.tanh(gdrive), media = p.media | 0;
    // LPF 7000 for the dirty tape
    const lc = 1 / Math.tan(7000 * TAU / sr * 0.5), lc2 = lc * lc, ls = lc * Math.SQRT2;
    const la0 = 1 / (1 + ls + lc2), lb1 = -2 * (1 - lc2) * la0, lb2 = -(1 - ls + lc2) * la0;
    const tlen = this.tape[0].length, hpc = Math.exp(-TAU * 40 / sr);
    const st = this.st, sbw = 0.1;
    // the static's swept band-pass (BPF, rq 0.1) at this block's frequency
    const sf = 400 * Math.pow(10, (this.stepLfn1Block(st.f1, n) + 1) / 2), spf = sf * TAU / sr;
    const sC = 1 / Math.tan(sbw * spf * 0.5), sD = 2 * Math.cos(spf);
    const sa0 = 1 / (1 + sC), sb1 = sC * sD * sa0, sb2 = (1 - sC) * sa0;
    const wf = 700 * Math.pow(3000 / 700, (this.stepLfn1Block(st.f2, n) + 1) / 2);

    for (let s = 0; s < n; s++) {
      const xl = (inL ? inL[s] : 0) * l.adc, xr = (inR ? inR[s] : 0) * l.adc;
      // writer: the grains come back in, high-passed (40 Hz); what's written is soft-clipped
      if (run) {
        const hl = hpc * (this.hyL + this.backL - this.hxL); this.hxL = this.backL; this.hyL = hl;
        const hr = hpc * (this.hyR + this.backR - this.hxR); this.hxR = this.backR; this.hyR = hr;
        bufL[this.head] = softclip(xl + hl * l.fb);
        bufR[this.head] = softclip(xr + hr * l.fb);
        this.follow(this.ampReel, Math.abs(bufL[this.head] + bufR[this.head]) * 0.5);
        this.head = (this.head + 1) % frames;
      }
      if (!run) this.follow(this.ampReel, 0);
      this.follow(this.ampIn, Math.abs(xl + xr) * 0.5);
      // grains: an impulse (or, with jitter, a random dust) starts one
      this.imp += dens / sr;
      if (this.imp >= 1) { this.imp -= 1; if (rand() < 1 - jitter) this.startGrain(sr, frames); }
      if (rand() < dens / sr && rand() < jitter) this.startGrain(sr, frames);
      let wl = 0, wr = 0;
      for (const g of this.grains) {
        if (!g.on) continue;
        const i0 = Math.floor(g.pos), fr = g.pos - i0, i1 = (i0 + 1) % frames;
        const e = this.envAt(g.env, g.i / g.n);
        wl += (bufL[i0] + (bufL[i1] - bufL[i0]) * fr) * e * g.gl;
        wr += (bufR[i0] + (bufR[i1] - bufR[i0]) * fr) * e * g.gr;
        g.pos += g.rate; if (g.pos >= frames) g.pos -= frames; if (g.pos < 0) g.pos += frames;
        if (++g.i >= g.n) g.on = false;
      }
      wl *= l.amp; wr *= l.amp;
      this.backL = wl; this.backR = wr;
      // filter
      if (ftype === 1 || ftype === 2) {
        const sg = ftype === 1 ? 2 : -2;
        let y = fa0 * wl + fb1 * this.fL1 + fb2 * this.fL2; wl = y + sg * this.fL1 + this.fL2; this.fL2 = this.fL1; this.fL1 = y;
        y = fa0 * wr + fb1 * this.fR1 + fb2 * this.fR2; wr = y + sg * this.fR1 + this.fR2; this.fR2 = this.fR1; this.fR1 = y;
      } else if (ftype === 3) {
        let y = wl + fb1 * this.fL1 + fb2 * this.fL2; wl = fa0 * (y - this.fL2); this.fL2 = this.fL1; this.fL1 = y;
        y = wr + fb1 * this.fR1 + fb2 * this.fR2; wr = fa0 * (y - this.fR2); this.fR2 = this.fR1; this.fR1 = y;
      }
      wl = Math.tanh(wl * gdrive) / tg; wr = Math.tanh(wr * gdrive) / tg;
      // media, after Beads
      this.tape[0][this.tw] = wl; this.tape[1][this.tw] = wr;
      if (media === 1) {
        this.latch[0] += 24000 / sr;
        if (this.latch[0] >= 1) { this.latch[0] -= 1; this.latch[1] = wl; this.latch[2] = wr; }
        wl = Math.round(this.latch[1] * 2048) / 2048; wr = Math.round(this.latch[2] * 2048) / 2048;
      } else if (media >= 2) {
        const depth = media === 2 ? 1 : 3;
        this.osc += 6.3 / sr;
        const d = (0.012 + this.stepNoise2() * 0.002 * depth + Math.sin(TAU * this.osc) * 0.0002 * depth) * sr;
        const rp = (this.tw - d + tlen) % tlen, r0 = Math.floor(rp), rf = rp - r0, r1 = (r0 + 1) % tlen;
        let dl = this.tape[0][r0] + (this.tape[0][r1] - this.tape[0][r0]) * rf;
        let dr = this.tape[1][r0] + (this.tape[1][r1] - this.tape[1][r0]) * rf;
        if (media === 2) {
          wl = Math.tanh(dl * 1.4) / 1.4; wr = Math.tanh(dr * 1.4) / 1.4;
        } else {
          dl = Math.tanh(dl * 2.2) / 2.2; dr = Math.tanh(dr * 2.2) / 2.2;
          let y = dl + lb1 * this.lL1 + lb2 * this.lL2; wl = la0 * (y + 2 * this.lL1 + this.lL2); this.lL2 = this.lL1; this.lL1 = y;
          y = dr + lb1 * this.lR1 + lb2 * this.lR2; wr = la0 * (y + 2 * this.lR1 + this.lR2); this.lR2 = this.lR1; this.lR1 = y;
          const h = this.pinkNoise() * 0.006; wl += h; wr += h;
        }
      }
      this.tw = (this.tw + 1) % tlen;
      // the static: hiss, crackle, a band of noise and a whistling carrier drifting past
      let stat = 0;
      if (l.static > 0.0001) {
        const w = rand() * 2 - 1;
        const y = w + sb1 * st.b1 + sb2 * st.b2; const bp = sa0 * (y - st.b2); st.b2 = st.b1; st.b1 = y;
        st.sine += wf / sr;
        stat = (this.pinkNoise() * 0.3 + (rand() < 40 / sr ? rand() * 0.5 : 0) + bp * 2
          + Math.sin(TAU * st.sine) * 0.04) * l.static;
      }
      const dry = 1 - l.mix;
      out[0][s] = xl * dry + wl * l.mix + stat;
      out[1][s] = xr * dry + wr * l.mix + stat;
      sendOut[0][s] = wl * l.send; sendOut[1][s] = wr * l.send;
    }
    if ((this.report += n) >= sr / 60) {
      this.report = 0;
      this.port.postMessage({ amp_in: this.ampIn.y, amp_reel: this.ampReel.y, head: this.head / sr });
    }
    return true;
  }
  follow(f, x) { f.y = x + (f.y - x) * (x > f.y ? f.ca : f.cr); }
  stepLfn1Block(n, frames) { let v = 0; for (let i = 0; i < frames; i++) v = this.stepLfn1(n); return v; }
  // pink noise (Paul Kellet's filter), about -1..1
  pinkNoise() {
    const b = this.pink, w = rand() * 2 - 1;
    b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759;
    b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856;
    b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980;
    const v = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362; b[6] = w * 0.115926;
    return v * 0.11;
  }
}
registerProcessor("pollen", Pollen);

// Limiter.ar(sig, 0.95, 0.01), near enough: the signal waits 10 ms while the gain comes down
// to meet its peak (held for those 10 ms), then recovers over about 0.1 s
class PollenLimit extends AudioWorkletProcessor {
  constructor() {
    super();
    this.L = Math.round(0.01 * sampleRate);
    this.dl = [new Float32Array(this.L), new Float32Array(this.L)];
    this.i = 0; this.g = 1; this.hold = 1; this.left = 0;
    this.rel = 1 - Math.exp(-1 / (0.1 * sampleRate));
  }
  process(inputs, outputs) {
    const inp = inputs[0], out = outputs[0], n = out[0].length, L = this.L;
    for (let s = 0; s < n; s++) {
      const xl = inp && inp[0] ? inp[0][s] : 0, xr = inp && inp[1] ? inp[1][s] : xl;
      const peak = Math.max(Math.abs(xl), Math.abs(xr));
      const target = peak > 0.95 ? 0.95 / peak : 1;
      if (target <= this.hold || this.left <= 0) { this.hold = target; this.left = L; } else this.left--;
      this.g += (this.hold - this.g) * (this.hold < this.g ? 5 / L : this.rel);
      const yl = this.dl[0][this.i], yr = this.dl[1][this.i];
      this.dl[0][this.i] = xl; this.dl[1][this.i] = xr; this.i = (this.i + 1) % L;
      out[0][s] = Math.max(-1, Math.min(1, yl * this.g));
      out[1][s] = Math.max(-1, Math.min(1, yr * this.g));
    }
    return true;
  }
}
registerProcessor("pollen-limit", PollenLimit);
`;

// A made-up broadcast, standing in for the radio: a slow chord progression, a melody that
// wanders a pentatonic, soft hats and now and then a voice-like murmur, with rests and a break
// every few bars (a host talking over nothing), so it has the ups and downs of real radio. Not
// music to keep, just something with notes, rhythm, gaps and talk to granulate.
function demo(ctx) {
  const out = ctx.createGain(); out.gain.value = 0.5;
  const pad = ctx.createBiquadFilter(); pad.type = "lowpass"; pad.frequency.value = 1400; pad.connect(out);
  const padGain = ctx.createGain(); padGain.gain.value = 0.025; padGain.connect(pad);
  const oscs = [0, 1, 2].map(() => {
    const o = ctx.createOscillator(); o.type = "sawtooth"; o.connect(padGain); o.start(); return o;
  });
  const noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
  const nd = noise.getChannelData(0); for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;
  const CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]];
  const SCALE = [69, 72, 74, 76, 79, 81, 84];
  const hz = n => 440 * Math.pow(2, (n - 69) / 12);
  let next = ctx.currentTime + 0.1, step = 0, note = 3;
  function hat(t) {
    const s = ctx.createBufferSource(); s.buffer = noise;
    const hp = ctx.createBiquadFilter(); hp.type = "highpass"; hp.frequency.value = 7000;
    const g = ctx.createGain(); g.gain.setValueAtTime(0.12, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.05);
    s.connect(hp); hp.connect(g); g.connect(out); s.start(t, Math.random() * 0.5, 0.06);
  }
  function lead(t, n, len) {
    const o = ctx.createOscillator(); o.type = "triangle"; o.frequency.value = hz(n);
    const g = ctx.createGain(); g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.18, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.001, t + len);
    o.connect(g); g.connect(out); o.start(t); o.stop(t + len + 0.05);
  }
  function murmur(t) { // a few "syllables": a buzzy source through two moving formants
    const o = ctx.createOscillator(); o.type = "sawtooth"; o.frequency.value = 110 + Math.random() * 40;
    const g = ctx.createGain(); g.gain.value = 0;
    const f1 = ctx.createBiquadFilter(), f2 = ctx.createBiquadFilter();
    [f1, f2].forEach(f => { f.type = "bandpass"; f.Q.value = 8; o.connect(f); f.connect(g); });
    g.connect(out);
    for (let k = 0; k < 6; k++) {
      const s = t + k * 0.18;
      f1.frequency.setValueAtTime(300 + Math.random() * 500, s); f2.frequency.setValueAtTime(900 + Math.random() * 1400, s);
      g.gain.setValueAtTime(0, s); g.gain.linearRampToValueAtTime(0.5, s + 0.04); g.gain.linearRampToValueAtTime(0, s + 0.16);
    }
    o.start(t); o.stop(t + 1.2);
  }
  const timer = setInterval(() => {
    while (next < ctx.currentTime + 0.3) { // an eighth at 100 bpm
      const bar = step % 64, brk = bar >= 52; // the last bar and a half of every eight: a break
      if (step % 16 === 0) CHORDS[(step / 16) % 4].forEach((n, i) => oscs[i].frequency.setValueAtTime(hz(n - 12), next));
      padGain.gain.setTargetAtTime(brk ? 0 : 0.025, next, 0.05);
      if (!brk && step % 2 === 1) hat(next);
      if (!brk && Math.random() < 0.45) { note = Math.max(0, Math.min(SCALE.length - 1, note + Math.round(Math.random() * 4 - 2))); lead(next, SCALE[note], 0.2); }
      if (bar === 53 || (step % 32 === 24 && Math.random() < 0.4)) murmur(next);
      next += 0.3; step++;
    }
  }, 100);
  return { output: out, stop() { clearInterval(timer); oscs.forEach(o => o.stop()); } };
}

NornsWeb.engines.Pollen = () => {
  const p = { ...DEFAULTS };           // every parameter sent so far
  let reel = 15, A = null;             // A: { ctx, node, verb, level } once started
  const polls = {};                    // the engine's polls, as the worklet last reported them
  const post = m => A && A.node.port.postMessage(m);
  // .lag(t) on a level: SC's Lag reaches 60 dB in t seconds
  const lagTo = (param, v, t) => param.setTargetAtTime(v, A.ctx.currentTime, t / 6.9);

  async function start(ctx, out) {
    const url = URL.createObjectURL(new Blob([PROCESSOR], { type: "text/javascript" }));
    await ctx.audioWorklet.addModule(url);
    const node = new AudioWorkletNode(ctx, "pollen", { numberOfInputs: 1, numberOfOutputs: 2,
      outputChannelCount: [2, 2], processorOptions: { params: p, reel } });
    node.port.onmessage = e => Object.assign(polls, e.data);
    const level = ctx.createGain(); level.gain.value = p.level;
    const limit = new AudioWorkletNode(ctx, "pollen-limit", { outputChannelCount: [2] });
    node.connect(level, 0); level.connect(limit); limit.connect(out);
    // the reverb: MiVerb, as the engine has it (time and freeze controls, the rest literals);
    // if the mi-UGens don't load, a plain convolution of decaying noise stands in
    let verb = null;
    try {
      if (!window.MiUGens) await new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = `${BASE}mi-ugens-node.js`; s.onload = resolve; s.onerror = () => reject(new Error("mi-ugens-node.js not found"));
        document.head.appendChild(s);
      });
      const mi = await MiUGens.load(ctx, BASE, ["MiVerb"]);
      verb = mi.node("MiVerb", { time: { rate: "control", value: p.vsize, lag: 0.2 }, drywet: 1, damp: 0.5, hp: 0.05,
        freeze: { rate: "control", value: p.vfreeze }, diff: 0.7 });
      node.connect(verb, 1); verb.connect(level);
    } catch (e) {
      console.warn("pollen: no MiVerb in the browser, a plain reverb stands in:", e);
      const conv = ctx.createConvolver(), len = ctx.sampleRate * 3, ir = ctx.createBuffer(2, len, ctx.sampleRate);
      for (let c = 0; c < 2; c++) { const d = ir.getChannelData(c); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3); }
      conv.buffer = ir; node.connect(conv, 1); conv.connect(level);
    }
    const src = demo(ctx);
    src.output.connect(node);
    A = { ctx, node, verb, level, src };
  }

  return {
    start,
    set(k, v) {
      if (!(k in DEFAULTS)) { console.warn(`pollen: unknown parameter ${k}`); return; }
      p[k] = v;
      if (!A) return;
      if (k === "level") lagTo(A.level.gain, v, 0.1);
      else if (k === "vsize" && A.verb) A.verb.set({ time: v });
      else if (k === "vfreeze" && A.verb) A.verb.set({ freeze: v });
      else post({ set: [k, v] });
    },
    reel(seconds) { reel = seconds; post({ reel: seconds }); },
    // the engine's polls: amp_in, amp_reel, head (nothing until the sound is on)
    poll(name) { return polls[name]; },
    clear() { post({ clear: true }); },
  };
};
})();
