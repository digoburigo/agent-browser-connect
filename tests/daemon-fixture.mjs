import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';

const registry = new Map();
const connections = new Set();
let connectionId = 0;
const exists = (entry, name) => fs.existsSync(path.join(entry.stateDir, name));
const read = (entry, name, fallback = '') => {
  try { return fs.readFileSync(path.join(entry.stateDir, name), 'utf8').trim(); }
  catch { return fallback; }
};
const touch = (entry, name) => fs.writeFileSync(path.join(entry.stateDir, name), '');
const remove = (entry, ...names) => names.forEach(name => fs.rmSync(path.join(entry.stateDir, name), { force: true }));
const event = (entry, data) => fs.appendFileSync(entry.commandLog + '.events', JSON.stringify(data) + '\n');

function targets(entry) {
  const primary = { tabId: 't1', targetId: read(entry, 'target-id', 'A1111111111111111111111111111111'), label: null,
    active: true, title: 'Owned', type: 'page', url: read(entry, 'url', 'about:blank') };
  const tabs = exists(entry, 'tab-closed') ? [] : [primary];
  if (exists(entry, 'swap-tab')) {
    primary.active = exists(entry, 'swap-bound-primary');
    tabs.push({ ...primary, tabId: 't2', targetId: 'D4444444444444444444444444444444', title: 'New', url: 'about:blank', active: !primary.active });
  } else if (exists(entry, 'drifted') || exists(entry, 'extra-target') ||
      (entry.mode === 'drift-before' && !exists(entry, 'restored'))) {
    const foreignActive = exists(entry, 'drifted') || (entry.mode === 'drift-before' && !exists(entry, 'restored'));
    primary.active = !foreignActive;
    tabs.push({ ...primary, tabId: 't2', targetId: 'B2222222222222222222222222222222', title: 'Foreign', url: 'about:blank', active: foreignActive });
  }
  return tabs.filter(tab => !exists(entry, 'closed-' + tab.targetId));
}

async function retire(entry) {
  if (!entry.listener) return;
  const listener = entry.listener;
  entry.listener = undefined;
  // Existing transactions may finish their response before the endpoint retires.
  await new Promise(resolve => { listener.close(resolve); for (const socket of entry.sockets) socket.end(); });
  event(entry, { kind: 'retired' });
}

async function register(data) {
  const key = data.socketDir + '/' + data.session;
  let entry = registry.get(key);
  if (!entry) {
    entry = { sockets: new Set() };
    registry.set(key, entry);
  }
  Object.assign(entry, data);
  if (!exists(entry, 'active')) await retire(entry);
  else if (entry.session && !entry.listener) {
    const address = path.join(entry.socketDir, entry.session + '.sock');
    if (Buffer.byteLength(address) > 103) throw new Error('fixture socket path exceeds 103 bytes');
    const listener = net.createServer(socket => {
      const connection = ++connectionId;
      entry.sockets.add(socket);
      connections.add(socket);
      event(entry, { kind: 'connection', connection });
      socket.on('error', () => {});
      socket.on('close', () => { entry.sockets.delete(socket); connections.delete(socket); });
      let buffer = '';
      socket.on('data', chunk => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end);
          buffer = buffer.slice(end + 1);
          const request = JSON.parse(line);
          event(entry, { kind: 'request', connection, ...request });
          let success = true, data;
          switch (request.action) {
            case 'session_info':
              data = { session: entry.session, socketDir: entry.socketDir, backgroundPid: process.pid, browserLaunched: true };
              break;
            case 'unroute':
              success = entry.mode !== 'unroute-fail' && exists(entry, 'active');
              data = { unrouted: 'all' };
              break;
            case 'tab_list':
              success = entry.mode !== 'tab-list-fail';
              data = { tabs: targets(entry) };
              break;
            case 'tab_close': {
              const tab = typeof request.tabId === 'string' && /^[0-9a-f]{16,}$/i.test(request.tabId)
                ? targets(entry).find(tab => tab.targetId === request.tabId) : undefined;
              success = !!tab;
              if (tab) {
                if (tab.targetId === read(entry, 'target-id', 'A1111111111111111111111111111111')) touch(entry, 'tab-closed');
                else if (tab.targetId === 'D4444444444444444444444444444444') remove(entry, 'swap-tab', 'swap-bound-primary');
                else touch(entry, 'closed-' + tab.targetId);
                data = { tabId: tab.tabId, targetId: tab.targetId, label: tab.label, closed: true };
                event(entry, { kind: 'target-closed', targetId: tab.targetId });
              }
              break;
            }
            case 'close':
              data = { closed: true };
              success = entry.mode !== 'close-fail';
              if (success && entry.mode !== 'close-no-exit' && !exists(entry, 'replacement-failed')) {
                if (entry.mode === 'close-delayed') fs.writeFileSync(path.join(entry.stateDir, 'closing'), '2\n');
                else {
                  if (entry.mode === 'swap-new-tab') touch(entry, 'swap-tab');
                  remove(entry, 'active');
                }
                event(entry, { kind: 'shutdown', active: exists(entry, 'active') });
              }
              break;
            default: success = false;
          }
          if (request.action === 'close' && entry.mode === 'close-lost-response') {
            event(entry, { kind: 'response-lost' });
            socket.destroy();
          } else socket.write(JSON.stringify({ id: request.id, success, data: data ?? {}, ...(success ? {} : { error: 'fixture refusal' }) }) + '\n');
          if (!exists(entry, 'active')) void retire(entry);
        }
      });
    });
    await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(address, resolve); });
    fs.chmodSync(address, 0o600);
    entry.listener = listener;
  }
  if (data.phase === 'cli') event(entry, { kind: 'cli', args: data.args, timeout: data.timeout });
  if (data.phase === 'diagnostic') event(entry, { kind: 'diagnostic', active: exists(entry, 'active'), timeout: data.timeout });
  if (data.phase === 'cli' && data.mode === 'expire-before-admin' && data.args.includes('--version')) {
    remove(entry, 'active');
    for (const current of registry.values()) {
      if (current.stateDir === entry.stateDir) await retire(current);
    }
    event(entry, { kind: 'expired-before-admin' });
  }
}

const server = net.createServer(socket => {
  connections.add(socket);
  socket.on('error', () => {});
  socket.on('close', () => connections.delete(socket));
  let buffer = '';
  socket.on('data', async chunk => {
    buffer += chunk;
    if (!buffer.includes('\n')) return;
    socket.pause();
    try { await register(JSON.parse(buffer)); socket.end('ok\n'); }
    catch (error) { socket.end('error ' + error.message + '\n'); }
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.PORT_FILE, String(server.address().port)));
process.on('SIGTERM', () => {
  for (const socket of connections) socket.destroy();
  for (const entry of registry.values()) entry.listener?.close();
  server.close(() => process.exit(0));
});
