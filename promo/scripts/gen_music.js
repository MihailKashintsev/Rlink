// Generates an original, royalty-free ambient brand bed (no downloads, no deps).
// Warm pad + soft sub pulse + gentle pluck arp → public/music.wav (stereo 44.1k).
const fs = require("fs");
const path = require("path");

const SR = 44100;
const DUR = 20.0; // seconds
const N = Math.floor(SR * DUR);
const L = new Float64Array(N);
const R = new Float64Array(N);

const BPM = 88;
const beat = 60 / BPM;
const bar = beat * 4;

// Chord progression (semitones from A2=110Hz region). Warm, hopeful.
const A2 = 110.0;
const semi = (n) => A2 * Math.pow(2, n / 12);
// i: Am, VI: F, III: C, VII: G  → roots & triads (add9 colour)
const chords = [
  { root: 0, notes: [0, 7, 12, 16, 19] }, // Am(add)
  { root: -4, notes: [-4, 3, 8, 12, 15] }, // F
  { root: 3, notes: [3, 10, 15, 19, 22] }, // C
  { root: -2, notes: [-2, 5, 10, 14, 17] }, // G
];

const soft = (x) => Math.tanh(x * 1.4) / 1.4; // gentle saturation/limit

// pad voice: detuned sines with slow attack/release per bar
function padAt(t, freq, barPhase) {
  const env =
    Math.min(1, barPhase / 0.6) * // attack
    Math.min(1, (bar - barPhase) / 0.8); // release toward bar end
  const vib = 1 + 0.003 * Math.sin(2 * Math.PI * 5 * t);
  const a = Math.sin(2 * Math.PI * freq * vib * t);
  const b = Math.sin(2 * Math.PI * freq * 1.003 * t);
  const c = 0.5 * Math.sin(2 * Math.PI * freq * 2 * t);
  return ((a + b + c) / 2.5) * Math.max(0, env);
}

for (let i = 0; i < N; i++) {
  const t = i / SR;
  const barIdx = Math.floor(t / bar);
  const chord = chords[barIdx % chords.length];
  const barPhase = t - barIdx * bar;

  // pad
  let pad = 0;
  for (const n of chord.notes) pad += padAt(t, semi(n), barPhase);
  pad /= chord.notes.length;

  // sub bass pulse on each beat
  const beatPhase = (t % beat) / beat;
  const bassEnv = Math.pow(1 - beatPhase, 2.5);
  const bass = Math.sin(2 * Math.PI * semi(chord.root) * 0.5 * t) * bassEnv * 0.6;

  // pluck arp (eighth notes), bright but quiet
  const eighth = beat / 2;
  const arpIdx = Math.floor(t / eighth);
  const arpPhase = (t % eighth) / eighth;
  const arpNote = chord.notes[arpIdx % chord.notes.length] + 12;
  const arpEnv = Math.pow(1 - arpPhase, 4);
  const arp =
    Math.sin(2 * Math.PI * semi(arpNote) * t) * arpEnv * 0.18;

  // master fade in/out
  const fade =
    Math.min(1, t / 1.5) * Math.min(1, (DUR - t) / 2.0);

  const mix = soft(pad * 0.55 + bass + arp) * 0.85 * fade;
  // tiny stereo width on arp
  L[i] = mix - arp * 0.06;
  R[i] = mix + arp * 0.06;
}

// write 16-bit stereo WAV
const bytesPerSample = 2;
const dataLen = N * 2 * bytesPerSample;
const buf = Buffer.alloc(44 + dataLen);
buf.write("RIFF", 0);
buf.writeUInt32LE(36 + dataLen, 4);
buf.write("WAVE", 8);
buf.write("fmt ", 12);
buf.writeUInt32LE(16, 16);
buf.writeUInt16LE(1, 20);
buf.writeUInt16LE(2, 22);
buf.writeUInt32LE(SR, 24);
buf.writeUInt32LE(SR * 2 * bytesPerSample, 28);
buf.writeUInt16LE(2 * bytesPerSample, 32);
buf.writeUInt16LE(16, 34);
buf.write("data", 36);
buf.writeUInt32LE(dataLen, 40);
let o = 44;
for (let i = 0; i < N; i++) {
  const l = Math.max(-1, Math.min(1, L[i]));
  const r = Math.max(-1, Math.min(1, R[i]));
  buf.writeInt16LE((l * 32767) | 0, o);
  o += 2;
  buf.writeInt16LE((r * 32767) | 0, o);
  o += 2;
}
const out = path.join(__dirname, "..", "public", "music.wav");
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, buf);
console.log("wrote", out, (buf.length / 1024 / 1024).toFixed(2), "MB");
