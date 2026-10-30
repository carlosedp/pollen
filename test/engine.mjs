// Renders lib/Engine_Pollen.js's worklet offline in node, to check the browser's engine makes
// the sound it should: grains from the reel, freeze holding it, every media, filter and the
// static, the limiter, and never a NaN or a runaway level.
//
//   node test/engine.mjs        (from the repo root)

import fs from "node:fs";

const src = fs.readFileSync("lib/Engine_Pollen.js", "utf8");
const PROCESSOR = src.match(/const PROCESSOR = `([\s\S]*?)`;\n/)[1].replace(/\\\\/g, "\\");
const DEFAULTS = Function(`return ${src.match(/const DEFAULTS = ({[\s\S]*?});/)[1]}`)();

const SR = 48000, BLOCK = 128;
const procs = {};
const reports = [];
class AudioWorkletProcessor { constructor() { this.port = { onmessage: null, postMessage: m => reports.push(m) }; } }
Function("AudioWorkletProcessor", "registerProcessor", "sampleRate", PROCESSOR)(
  AudioWorkletProcessor, (name, cls) => { procs[name] = cls; }, SR);

const proc = new procs.pollen({ processorOptions: { params: { ...DEFAULTS }, reel: 8 } });
const limit = new procs["pollen-limit"]();
const send = m => proc.port.onmessage({ data: m });
const set = (k, v) => send({ set: [k, v] });

// the input: a chord of sines, on and off, like music with gaps
let t = 0, inputOn = true;
function render(seconds) {
  let sum = 0, sendSum = 0, peak = 0, n = 0;
  for (let b = 0; b < Math.round(seconds * SR / BLOCK); b++) {
    const inL = new Float32Array(BLOCK), inR = new Float32Array(BLOCK);
    for (let i = 0; i < BLOCK; i++, t++) {
      const x = inputOn ? 0.2 * (Math.sin(2 * Math.PI * 220 * t / SR) + Math.sin(2 * Math.PI * 330 * t / SR)) : 0;
      inL[i] = x; inR[i] = x;
    }
    const out = [new Float32Array(BLOCK), new Float32Array(BLOCK)];
    const rev = [new Float32Array(BLOCK), new Float32Array(BLOCK)];
    proc.process([[inL, inR]], [out, rev]);
    const lim = [new Float32Array(BLOCK), new Float32Array(BLOCK)];
    limit.process([out], [lim]);
    for (let c = 0; c < 2; c++) for (let i = 0; i < BLOCK; i++) {
      const v = lim[c][i];
      if (!Number.isFinite(v)) throw new Error(`NaN or infinity at ${t / SR} s`);
      sum += v * v; sendSum += rev[c][i] ** 2; peak = Math.max(peak, Math.abs(v)); n++;
    }
  }
  return { rms: Math.sqrt(sum / n), send: Math.sqrt(sendSum / n), peak };
}
const fails = [];
function check(label, cond, r) {
  console.log(`${cond ? "ok  " : "FAIL"} ${label.padEnd(44)} rms ${r.rms.toFixed(4)}  peak ${r.peak.toFixed(3)}`);
  if (!cond) fails.push(label);
}

let r = render(3);
check("grains and input, the defaults", r.rms > 0.01 && r.peak < 2, r);

set("mix", 1);
r = render(2);
check("grains alone", r.rms > 0.01 && r.peak < 2, r);
check("  and the reverb send", r.send > 0.001, { rms: r.send, peak: 0 });

// pressed: the input stops, the reel keeps playing what it caught
set("freeze", 1); inputOn = false;
r = render(3);
check("pressed, input gone: the reel still plays", r.rms > 0.01, r);
set("freeze", 0);
render(7); // the reel (8 s) fills with silence; grains read the last of the old for a moment
r = render(2);
check("released, input gone: it fades to silence", r.rms < 0.002, r);
inputOn = true;
render(3);

const digital = render(1.5).rms;
for (const [k, v, label] of [["media", 1, "vintage digital"], ["media", 2, "clean tape"], ["media", 3, "dirty tape"],
  ["ftype", 1, "low-pass"], ["ftype", 2, "high-pass"], ["ftype", 3, "band-pass"]]) {
  set(k, v); if (k === "ftype") set("cutoff", 800);
  r = render(1.5);
  check(label, r.rms > 0.003 && r.peak < 2 && (k !== "media" || Math.abs(Math.log10(r.rms / digital)) < 0.25), r);
}
set("media", 0); set("ftype", 0);

// feedback at its most, with dense long grains: loud, but bounded
set("fb", 0.85); set("density", 40); set("size", 1.5); set("pitch", 7); set("pitch_spread", 5);
r = render(6);
check("cross-pollination at its most: the limiter holds", r.peak <= 0.97, r);
set("fb", 0); set("density", 8); set("size", 0.15); set("pitch", 0); set("pitch_spread", 0);

// four heads, spread along the reel, a chord apart
set("heads", 4); set("hgap", 2); set("hp1", 4); set("hp2", 7); set("hp3", 12); set("density", 30);
r = render(2);
check("four heads, a chord apart", r.rms > 0.005 && r.peak <= 0.97, r);
set("heads", 1); set("hgap", 0); set("hp1", 0); set("hp2", 0); set("hp3", 0); set("density", 8);

set("reverse", 1); r = render(1.5);
check("all grains backwards", r.rms > 0.005, r);
set("reverse", 0);

set("mix", 0); inputOn = false; set("static", 1); render(0.3);
r = render(1.5);
check("static alone", r.rms > 0.01 && r.peak < 3, r);
set("static", 0);

send({ reel: 30 }); inputOn = true; set("mix", 1);
r = render(2);
check("a new 30 s reel catches again", r.rms > 0.005, r);
send({ clear: true }); inputOn = false;
render(0.1); // what was already on its way out (the limiter looks 10 ms ahead)
r = render(1);
check("cleared, input gone: silence", r.rms < 0.002, r);

// the polls it reports: numbers, the reel's level up while it's caught something
const last = reports[reports.length - 1];
check("polls: amp_in, amp_reel and head reported",
  reports.length > 100 && ["amp_in", "amp_reel", "head"].every(k => Number.isFinite(last[k])), { rms: reports.length, peak: 0 });
check("  amp_reel follows the tape", reports.some(m => m.amp_reel > 0.05), { rms: Math.max(...reports.map(m => m.amp_reel)), peak: 0 });

if (fails.length) { console.log(`${fails.length} failed`); process.exit(1); }
console.log("all ok");
