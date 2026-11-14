// Tellavision Follow along (Nov 14 2026): times syncprint in Apple's jsc shell.
// claude-native-check.yml runs it after Sources/syncprint.js, with the JIT on
// and with --useJIT=false (an app's JavaScriptCore has no JIT). A made-up
// film (tones that change every tenth to third of a second, the same steps as
// FollowAlongTests), its fingerprint, the matcher, three 8 second clips.
// Prints numbers only. Never fails the build.
(function () {
  var label = (typeof arguments !== 'undefined' && arguments.length) ? String(arguments[0]) : '';
  if (typeof SyncPrint === 'undefined') {
    print('time-match: SyncPrint is missing');
    return;
  }
  var SP = SyncPrint;
  var RATE = 8000;
  function rng(seed) {
    var s = (seed >>> 0) || 1;
    return function () {
      s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
      return s / 4294967296;
    };
  }
  function film(seconds, seed) {
    var r = rng(seed), n = Math.floor(seconds * RATE), x = new Float32Array(n), t = 0, i;
    while (t < n) {
      var len = Math.floor((0.12 + r() * 0.25) * RATE);
      var f1 = 350 + r() * 2900, f2 = Math.min(3300, f1 * (1.25 + r() * 0.35));
      var a = 0.25 + r() * 0.35, att = 0.01 * RATE, rel = 0.03 * RATE;
      for (i = 0; i < len && t + i < n; i++) {
        var g = 1, left = len - 1 - i;
        if (i < att) g = i / att;
        if (left < rel) g = Math.min(g, left / rel);
        x[t + i] += a * g * (Math.sin(2 * Math.PI * f1 * i / RATE) + 0.6 * Math.sin(2 * Math.PI * f2 * i / RATE));
      }
      t += len;
    }
    var out = new Int16Array(n);
    for (i = 0; i < n; i++) {
      var v = x[i] * 0.5 + (r() - 0.5) * 0.004;
      out[i] = Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
    }
    return out;
  }
  function clip(src, startSec, sec, gain, noise, seed) {
    var r = rng(seed), a = Math.floor(startSec * RATE), n = Math.floor(sec * RATE), out = new Int16Array(n), i;
    for (i = 0; i < n; i++) {
      var v = src[a + i] / 32767 * gain + (r() - 0.5) * 2 * noise;
      out[i] = Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
    }
    return out;
  }
  var f = film(300, 0x2468ACE);
  var t1 = Date.now();
  var bytes = SP.encode(SP.fingerprint(f));
  var t2 = Date.now();
  var m = SP.createMatcher(SP.decode(bytes));
  var t3 = Date.now();
  if (!m) {
    print('time-match: no matcher');
    return;
  }
  var times = [];
  var starts = [61.4, 177.0, 252.6];
  for (var k = 0; k < starts.length; k++) {
    var c = clip(f, starts[k], 8, 0.5, 0.05, 7 + k);
    var b = Date.now();
    var res = m.match(c);
    times.push((Date.now() - b) + (res.found ? '' : ' (not found)'));
  }
  print('jsc' + (label ? ' ' + label : '') + ', syncprint ' + SP.VERSION + ': 5 minute film; fingerprint ' + (t2 - t1) +
    ' ms; matcher ' + (t3 - t2) + ' ms; 8 s matches ' + times.join(', ') + ' ms');
})();
