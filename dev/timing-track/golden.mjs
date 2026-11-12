// Nov 11 2026: writes TimingTrackTests/timing-golden.json from the WEBSITE's own
// timing-track.mjs, so the Swift port (Sources/KadeTimingTrack.swift) is pinned to
// the same mouth picks for the same track. Run with real Node from a folder that
// holds copies of the fork's timing-track.mjs and avatar-expression.mjs:
//   node dev/timing-track/golden.mjs <folder with timing-track.mjs> > TimingTrackTests/timing-golden.json
// Regenerate after any change to either side's pick, table, lead or frame window.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const dir = process.argv[2];
if (!dir) throw new Error('usage: node golden.mjs <folder with timing-track.mjs>');
const tt = await import(pathToFileURL(path.join(dir, 'timing-track.mjs')).href);

// The web test's own track (timing-track.test.mjs), an iw11 track, and a longer
// track with a short closure, a seam (covered time with no span) and a gap in cov.
const tracks = {
  web: {
    v: 1, src: 'inworld', set: 'oxr', dur: 1000,
    vis: [[0, 100, 'sil'], [100, 300, 'aa'], [300, 310, 'PP'], [310, 500, 'aa'], [500, 600, 'oh']],
    w: [[100, 300, 'Hello'], [310, 480, 'there'], [520, 700, '[laugh]']],
    cov: [[0, 700]],
  },
  iw11: {
    v: 1, src: 'inworld', set: 'iw11', dur: 900,
    vis: [[0, 60, 'sil'], [60, 180, 'cdgknstxyz'], [180, 330, 'aei'], [330, 345, 'bmp'],
      [345, 470, 'o'], [470, 560, 'fv'], [560, 700, 'ee'], [700, 820, 'r']],
    cov: [[0, 900]],
  },
  long: {
    v: 1, src: 'inworld', set: 'oxr', dur: 2400,
    vis: [[0, 90, 'sil'], [90, 160, 'TH'], [160, 300, 'E'], [300, 318, 'FF'], [318, 420, 'ih'],
      [420, 520, 'kk'], [520, 610, 'SS'], [610, 760, 'aa'], [760, 768, 'PP'], [768, 900, 'ou'],
      [900, 980, 'nn'], [980, 1100, 'RR'], [1100, 1180, 'CH'], [1180, 1300, 'DD'],
      [1640, 1700, 'oh'], [1700, 1900, 'aa'], [1900, 1915, 'PP'], [1915, 2100, 'E'], [2100, 2300, 'sil']],
    cov: [[0, 1400], [1600, 2300]],
  },
};

const frameSets = {
  fps24: { step: 1000 / 24, phase: 0 },
  hz60: { step: 50, phase: 0 },
  hz60late: { step: 50, phase: 12.5 },
};
const strengths = [0.1, 0.4, 0.8];

const out = { generatedFrom: 'fork client/src/components/Chat/character/timing-track.mjs', leadMs: tt.LEAD_MS, cases: [] };
for (const [name, track] of Object.entries(tracks)) {
  for (const [frames, { step, phase }] of Object.entries(frameSets)) {
    for (const strength of strengths) {
      const picks = [];
      for (let ms = phase; ms < track.dur; ms += step) {
        const p = tt.trackPanelAt(track, ms, strength);
        picks.push(p == null ? '-' : String(p));
      }
      out.cases.push({ track: name, frames, step, phase, strength, picks: picks.join('') });
    }
  }
}
out.tracks = tracks;
out.moments = Object.fromEntries(Object.entries(tracks).map(([n, t]) => [n, tt.trackMoments(t)]));
process.stdout.write(JSON.stringify(out, null, 1) + '\n');
