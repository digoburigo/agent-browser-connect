import net from 'node:net';
import { lstatSync } from 'node:fs';
import path from 'node:path';

// Bash owns policy, metadata, CDP health proof and rollback authority. Native
// browser actions can still auto-redial if backend health changes after proof.
const MAX_BYTES = 256 * 1024;
const TOTAL_MS = 30000;
const CONNECT_MS = 1000;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const targetId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,256}$/.test(value);
const sameTarget = (a, b) => a.toLowerCase() === b.toLowerCase();
const failure = (status, reason) => Object.assign(new Error(reason), { status, reason });
const result = { outcome: 'refused', routes: 'not-attempted', target: 'not-attempted', reason: 'INVALID_ARGUMENTS' };
let socket, deadline, connectDeadline, pending, terminal, sequence = 0, bytes = 0;
let buffer = Buffer.alloc(0), mutationSubmitted = false;
const ioFailure = reason => failure(mutationSubmitted ? 9 : 3, reason);
function stop(error) {
  terminal ??= error;
  if (pending) { const { reject } = pending; pending = undefined; reject(terminal); }
  socket?.destroy();
}
function request(action, extra = {}, mutating = false) {
  if (terminal) return Promise.reject(terminal);
  const id = String(++sequence);
  return new Promise((resolve, reject) => {
    pending = { id, action, resolve, reject };
    if (mutating) {
      mutationSubmitted = true;
      if (action === 'unroute') result.routes = 'unverified';
      if (action === 'tab_close') result.target = 'unverified';
    }
    // A write attempt is uncertain even if the error arrives before its callback.
    socket.write(JSON.stringify({ id, action, ...extra }) + '\n', error => {
      if (error) stop(ioFailure('WRITE_FAILED'));
    });
  });
}
function receive(chunk) {
  bytes += chunk.length;
  if (bytes > MAX_BYTES) return stop(failure(mutationSubmitted ? 9 : 5, 'RESPONSE_TOO_LARGE'));
  buffer = Buffer.concat([buffer, chunk]);
  const end = buffer.indexOf(10);
  if (end < 0) return;
  if (!pending || end !== buffer.length - 1) return stop(failure(mutationSubmitted ? 9 : 5, 'INVALID_FRAME'));
  let response;
  try { response = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, end))); }
  catch { return stop(failure(mutationSubmitted ? 9 : 5, 'INVALID_FRAME')); }
  buffer = Buffer.alloc(0);
  if (!object(response) || response.id !== pending.id || typeof response.success !== 'boolean') {
    return stop(failure(mutationSubmitted ? 9 : 5, 'INVALID_ENVELOPE'));
  }
  const { action, resolve, reject } = pending;
  pending = undefined;
  if (object(response.data) && response.data.confirmation_required === true) {
    // A native success envelope can represent a refusal, not a completion.
    if (action === 'unroute') result.routes = 'not-attempted';
    if (action === 'tab_close') result.target = 'preserved';
    reject(failure(result.target === 'unverified' ? 9 : 5, 'CONFIRMATION_REQUIRED'));
  } else if (!response.success) {
    reject(failure(mutationSubmitted ? 9 : 5, 'NATIVE_FAILURE'));
  } else if (!object(response.data) || (response.error !== undefined && response.error !== null)) {
    reject(failure(mutationSubmitted ? 9 : 5, 'INVALID_ENVELOPE'));
  } else resolve(response.data);
}
function ownedPath(address, directory) {
  let stat;
  try { stat = lstatSync(address); }
  catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') throw failure(3, 'SOCKET_UNAVAILABLE');
    throw failure(5, 'UNSAFE_PATH');
  }
  if (stat.isSymbolicLink() || stat.uid !== process.getuid() ||
      (directory ? !stat.isDirectory() || (stat.mode & 0o022) !== 0 : !stat.isSocket() || (stat.mode & 0o022) !== 0)) {
    throw failure(5, 'UNSAFE_PATH');
  }
  return stat;
}
async function listTargets() {
  const data = await request('tab_list');
  if (!Array.isArray(data.tabs)) throw failure(mutationSubmitted ? 9 : 5, 'INVALID_TARGET_LIST');
  const targets = new Set(), stableIds = new Set(), labels = new Set();
  for (const tab of data.tabs) {
    if (!object(tab) || !targetId(tab.targetId) || typeof tab.tabId !== 'string' || !/^t[1-9][0-9]*$/.test(tab.tabId) ||
        typeof tab.active !== 'boolean' || !(tab.label === null || typeof tab.label === 'string') ||
        targets.has(tab.targetId.toLowerCase()) || stableIds.has(tab.tabId) ||
        (tab.label !== null && labels.has(tab.label))) {
      throw failure(mutationSubmitted ? 9 : 5, 'INVALID_TARGET_LIST');
    }
    targets.add(tab.targetId.toLowerCase()); stableIds.add(tab.tabId);
    if (tab.label !== null) labels.add(tab.label);
  }
  return data.tabs;
}
async function closeTarget(candidate, previous, discover) {
  const tabs = await listTargets();
  if (discover) {
    // Only the rollback caller may enter discovery. It must prove a new,
    // established pinned attachment and continuity under its transaction lock.
    // The wire list has no independent pin/ownership evidence.
    const active = tabs.filter(tab => tab.active);
    if (active.length !== 1) throw failure(5, 'ROLLBACK_UNPROVEN');
    candidate = active[0].targetId;
  }
  if (previous && sameTarget(candidate, previous)) {
    result.target = 'preserved'; throw failure(5, 'PREVIOUS_TARGET');
  }
  if (/^[tT][0-9]+$/.test(candidate)) {
    result.target = 'preserved'; throw failure(5, 'AMBIGUOUS_TARGET');
  }
  const owned = tabs.find(tab => tab.targetId === candidate);
  if (!owned) {
    // Native matching is case-insensitive. A differently cased ID cannot be
    // treated as absent and then accidentally resolve on a later invocation.
    if (tabs.some(tab => sameTarget(tab.targetId, candidate))) throw failure(5, 'AMBIGUOUS_TARGET');
    result.target = 'absent'; return;
  }
  if (!/^[0-9a-f]{16,}$/i.test(candidate)) {
    result.target = 'preserved'; throw failure(5, 'UNSUPPORTED_TARGET');
  }
  // Never replace an exact target with tN. A replacement backend may reuse tN.
  // Labels take precedence over label-shaped target IDs in native TabRef.
  if (tabs.some(tab => tab !== owned && tab.label === candidate)) {
    result.target = 'preserved'; throw failure(5, 'AMBIGUOUS_TARGET');
  }
  const closed = await request('tab_close', { tabId: candidate }, true);
  if (closed.closed !== true || closed.targetId !== candidate || closed.tabId !== owned.tabId) {
    throw failure(9, 'INVALID_COMPLETION');
  }
  const remaining = await listTargets();
  if (remaining.some(tab => sameTarget(tab.targetId, candidate))) throw failure(9, 'TARGET_STILL_PRESENT');
  result.target = 'closed';
}
async function main() {
  const [operation, session, socketDir, pid, ...args] = process.argv.slice(2);
  const counts = { 'clear-task-routes': 0, 'close-owned-target': 1, 'discard-new-attach-target': 2, 'close-daemon': 0 };
  if (!Object.hasOwn(counts, operation) || args.length !== counts[operation] ||
      typeof session !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(session) ||
      typeof socketDir !== 'string' || !path.isAbsolute(socketDir) || path.normalize(socketDir) !== socketDir ||
      /[\u0000-\u001f\u007f]/.test(socketDir) || !/^[1-9][0-9]*$/.test(pid ?? '') || !Number.isSafeInteger(Number(pid)) ||
      args.some(arg => !(operation === 'discard-new-attach-target' && arg === '') && !targetId(arg))) {
    throw failure(5, 'INVALID_ARGUMENTS');
  }
  const address = path.join(socketDir, `${session}.sock`);
  if (Buffer.byteLength(address) > 103) throw failure(5, 'INVALID_ARGUMENTS');
  const directory = ownedPath(socketDir, true), endpoint = ownedPath(address, false);
  deadline = setTimeout(() => stop(ioFailure('DEADLINE')), TOTAL_MS);
  socket = net.createConnection({ path: address });
  socket.on('data', receive);
  socket.on('error', () => stop(ioFailure('SOCKET_FAILURE')));
  socket.on('end', () => stop(ioFailure('RESPONSE_LOST')));
  socket.on('close', () => stop(ioFailure('SOCKET_CLOSED')));
  await new Promise((resolve, reject) => {
    pending = { reject };
    connectDeadline = setTimeout(() => stop(failure(3, 'CONNECT_DEADLINE')), CONNECT_MS);
    socket.once('connect', () => { clearTimeout(connectDeadline); pending = undefined; resolve(); });
  });
  const identity = await request('session_info');
  if (identity.session !== session || identity.socketDir !== socketDir || identity.backgroundPid !== Number(pid)) {
    throw failure(5, 'IDENTITY_MISMATCH');
  }
  const currentDir = ownedPath(socketDir, true), currentSocket = ownedPath(address, false);
  if (directory.dev !== currentDir.dev || directory.ino !== currentDir.ino ||
      endpoint.dev !== currentSocket.dev || endpoint.ino !== currentSocket.ino) throw failure(5, 'ADDRESS_CHANGED');
  if (operation !== 'close-daemon' && identity.browserLaunched !== true) throw failure(5, 'BROWSER_UNAVAILABLE');
  if (operation === 'clear-task-routes') {
    const data = await request('unroute', {}, true);
    if (data.unrouted !== 'all') throw failure(9, 'INVALID_COMPLETION');
    result.routes = 'cleared';
  } else if (operation === 'close-daemon') {
    const data = await request('close', {}, true);
    if (data.closed !== true) throw failure(9, 'INVALID_COMPLETION');
  } else {
    await closeTarget(args[0], args[1] ?? '', operation === 'discard-new-attach-target' && args[0] === '');
  }
  result.outcome = 'completed'; result.reason = 'COMPLETED';
}
try { await main(); process.exitCode = 0; }
catch (error) {
  const status = error.status ?? (mutationSubmitted ? 9 : 5);
  result.outcome = ({ 3: 'unavailable', 5: 'refused', 9: 'unknown' })[status];
  result.reason = error.reason ?? 'INTERNAL_FAILURE'; process.exitCode = status;
} finally {
  clearTimeout(deadline); clearTimeout(connectDeadline); socket?.destroy();
  for (const [key, value] of Object.entries(result)) process.stdout.write(`${key}=${value}\n`);
}
