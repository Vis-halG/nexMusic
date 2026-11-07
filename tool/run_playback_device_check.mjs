// Drives playback_device_check.dart through ADB and its loopback control API.
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const device = process.env.PLAYBACK_DEVICE ?? 'emulator-5554';
const soakSeconds = Number(process.argv[2] ?? 60);
const adb = join(process.env.LOCALAPPDATA, 'Android/sdk/platform-tools/adb.exe');
const packageName = 'com.thenex.nex_music';
const results = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const command = (...args) => execFileSync(adb, ['-s', device, ...args], { encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'pipe'] });
const require = (condition, message) => { if (!condition) throw Error(message); };
async function api(path = '/status') {
  const response = await fetch('http://127.0.0.1:18766' + path, { signal: AbortSignal.timeout(15000) });
  require(response.ok, `Control API HTTP ${response.status}`);
  return path === '/status' ? response.json() : response.text();
}
async function check(name, body) {
  const start = Date.now();
  let result;
  try { result = { name, pass: true, seconds: (Date.now() - start) / 1000, details: await body() }; }
  catch (error) { result = { name, pass: false, error: String(error) }; }
  result.seconds = (Date.now() - start) / 1000;
  results.push(result);
  console.log(JSON.stringify(result));
}
function foreground() {
  return command('shell', 'dumpsys', 'activity', 'services', packageName).includes('isForeground=true');
}
async function wake() {
  command('shell', 'input', 'keyevent', '224');
  command('shell', 'input', 'keyevent', '82');
  command('shell', 'am', 'start', '-n', packageName + '/.MainActivity');
  await sleep(500);
}
async function progress(mode, locked = false, seconds = 10) {
  await wake();
  await api('/scenario?mode=' + mode);
  const before = await api();
  const pid = command('shell', 'pidof', packageName).trim();
  command('shell', 'input', 'keyevent', locked ? '223' : '3');
  await sleep(seconds * 1000);
  const after = await api();
  require(after.playing, 'Player stopped: ' + JSON.stringify(after));
  const transitions = after.selections.length - before.selections.length;
  require(transitions >= 2, 'Queue did not advance');
  require(pid === command('shell', 'pidof', packageName).trim(), 'Process changed or exited');
  require(foreground(), 'Media service lost foreground state');
  return { transitions, pid };
}
async function transportLocked() {
  command('shell', 'cmd', 'media_session', 'dispatch', 'pause');
  await sleep(1000);
  require(!(await api()).playing, 'Notification pause failed');
  require(foreground(), 'Temporary pause released foreground service');
  command('shell', 'cmd', 'media_session', 'dispatch', 'play');
  await sleep(3000);
  require((await api()).playing, 'Notification resume failed while locked');
  return { serviceRetainedDuringPause: true };
}
async function recoveryLocked() {
  await wake();
  await api('/scenario?mode=recover');
  command('shell', 'input', 'keyevent', '223');
  await sleep(12000);
  const state = await api();
  require(state.resolves === 2, 'Stream did not refresh once: ' + JSON.stringify(state));
  require(state.playing && state.positionMs > 3000, 'Recovered stream did not progress');
  require(foreground(), 'Recovery lost foreground service');
  return { resolves: state.resolves, positionMs: state.positionMs };
}

command('forward', 'tcp:18766', 'tcp:8766');
let deadline = Date.now() + 90000;
while (true) {
  try {
    const state = await api();
    if (state.phase === 'ready') break;
    if (Date.now() > deadline) throw Error('Restart the playback harness before rerunning');
    await sleep(1000);
  }
  catch (error) {
    if (Date.now() > deadline) throw Error('Launch playback_device_check.dart first: ' + error);
    await sleep(1000);
  }
}
await wake();
await api('/run');
deadline = Date.now() + 240000;
while (true) {
  const state = await api();
  if (state.phase === 'interactive') {
    results.push(...state.results);
    state.results.forEach(r => console.log(JSON.stringify(r)));
    break;
  }
  if (Date.now() > deadline) throw Error('Native playback suite timed out: ' + JSON.stringify(state));
  await sleep(2000);
}
for (const mode of ['sequential', 'gapless', 'crossfade']) {
  await check(mode + ' after switching to Home', () => progress(mode));
  await check(mode + ' with screen locked', () => progress(mode, true));
}
await check('notification pause and resume while locked', transportLocked);
await check('fresh stream recovery while locked', recoveryLocked);
for (const mode of ['gapless', 'crossfade']) {
  await check(mode + ' locked soak', () => progress(mode, true, soakSeconds));
}
await api('/stop');
await wake();
const report = { device, soakSecondsPerMode: soakSeconds,
  passed: results.filter(r => r.pass).length, failed: results.filter(r => !r.pass).length,
  results, diagnosticMessages: (await api()).errors };
const target = join(tmpdir(), 'nexmusic-playback-device-results.json');
writeFileSync(target, JSON.stringify(report, null, 2));
console.log('REPORT ' + target);
console.log(`RESULT ${report.passed} passed, ${report.failed} failed`);
process.exitCode = report.failed ? 1 : 0;
