import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtemp, rm, chmod, symlink, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const helper = fileURLToPath(new URL('../scripts/admin.mjs', import.meta.url));
const A = 'ABCDEF0123456789ABCDEF0123456789';
const B = '0123456789ABCDEF0123456789ABCDEF';
const tab = (targetId, tabId, active = false, label = null) => ({ targetId, tabId, active, label, title: '', url: 'about:blank', type: 'page' });
let passed = 0;
async function fixture(check, options = {}) {
  const dir = await mkdtemp('/tmp/ab-a-');
  await chmod(dir, 0o700);
  const requests = [], peers = new Set();
  let connections = 0, tabs = options.tabs ?? [tab(A, 't1', true), tab(B, 't2')];
  const server = net.createServer(socket => {
    connections++;
    peers.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => peers.delete(socket));
    let buffer = '';
    socket.on('data', data => {
      buffer += data;
      while (buffer.includes('\n')) {
        const end = buffer.indexOf('\n');
        const req = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        requests.push(req);
        let data;
        switch (req.action) {
          case 'session_info': data = { session: 's', socketDir: dir, backgroundPid: 123, browserLaunched: true, ...options.identity }; break;
          case 'unroute': data = { unrouted: 'all' }; break;
          case 'tab_list': data = { tabs }; break;
          case 'tab_close': {
            const target = typeof req.tabId === 'string' && /^[0-9a-f]{16,}$/i.test(req.tabId)
              ? tabs.find(t => t.targetId === req.tabId) : undefined;
            assert.ok(target, 'close must send a native hexadecimal target reference');
            tabs = tabs.filter(t => t !== target);
            data = { closed: true, targetId: target.targetId, tabId: target.tabId };
            break;
          }
          case 'close': data = { closed: true }; break;
          default: assert.fail('unexpected action');
        }
        const response = { id: req.id, success: true, data };
        if (options.reply?.(req, response, socket) === false) continue;
        const wire = JSON.stringify(response) + '\n';
        if (options.fragment) {
          socket.write(wire.slice(0, 7));
          setImmediate(() => socket.write(wire.slice(7)));
        } else socket.write(wire);
      }
    });
  });
  if (!options.noServer) await new Promise(resolve => server.listen(`${dir}/s.sock`, resolve));
  const run = (operation, args = [], address = dir) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper, operation, 's', address, '123', ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => stdout += d);
    child.stderr.on('data', d => stderr += d);
    child.on('error', reject);
    child.on('close', code => resolve({ code, fields: Object.fromEntries(stdout.trim().split('\n').map(l => l.split('='))), stderr }));
  });
  try { await check({ dir, requests, run, connections: () => connections, tabs: () => tabs }); passed++; }
  finally {
    for (const peer of peers) peer.destroy();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
}
const actions = f => f.requests.map(r => r.action);
await fixture(async f => {
  const r = await f.run('clear-task-routes');
  assert.equal(r.code, 0); assert.equal(r.fields.routes, 'cleared');
  assert.deepEqual(actions(f), ['session_info', 'unroute']); assert.equal(f.connections(), 1);
}, { fragment: true });
await fixture(async f => {
  assert.equal((await f.run('close-daemon')).code, 3);
  assert.deepEqual(actions(f), []);
}, { noServer: true });
for (const identity of [{ session: 'foreign' }, { backgroundPid: 124 }, { socketDir: '/foreign' }, { backgroundPid: null }]) {
  await fixture(async f => { assert.equal((await f.run('clear-task-routes')).code, 5); assert.deepEqual(actions(f), ['session_info']); }, { identity });
}
await fixture(async f => { assert.equal((await f.run('clear-task-routes')).code, 5); assert.deepEqual(actions(f), ['session_info']); }, { identity: { browserLaunched: false } });
await fixture(async f => { assert.equal((await f.run('close-daemon')).code, 0); }, { identity: { browserLaunched: false } });
await fixture(async f => {
  await chmod(f.dir, 0o777);
  assert.equal((await f.run('close-daemon')).code, 5); assert.equal(f.connections(), 0);
});
await fixture(async f => {
  await symlink(f.dir, `${f.dir}/alias`);
  assert.equal((await f.run('close-daemon', [], `${f.dir}/alias`)).code, 5); assert.equal(f.connections(), 0);
});
await fixture(async f => {
  await symlink('/tmp/nonexistent-admin-socket', `${f.dir}/s.sock`);
  assert.equal((await f.run('close-daemon')).code, 5);
}, { noServer: true });
await fixture(async f => {
  await writeFile(`${f.dir}/s.sock`, 'not a socket');
  assert.equal((await f.run('close-daemon')).code, 5);
}, { noServer: true });
for (const wire of ['{bad}\n', 'x'.repeat(270000), JSON.stringify({id:'wrong',success:true,data:{}})+'\n']) {
  await fixture(async f => { assert.equal((await f.run('close-daemon')).code, 5); assert.deepEqual(actions(f), ['session_info']); }, { reply(req, res, socket) { socket.write(wire); return false; } });
}
await fixture(async f => {
  const r = await f.run('clear-task-routes'); assert.equal(r.code, 5); assert.equal(r.fields.routes, 'not-attempted');
  assert.deepEqual(actions(f), ['session_info', 'unroute']);
}, { reply(req, res) { if (req.action === 'unroute') res.data = { confirmation_required: true }; } });
await fixture(async f => {
  const r = await f.run('close-owned-target', [A]); assert.equal(r.code, 0); assert.equal(r.fields.target, 'closed');
  assert.deepEqual(f.tabs().map(t => t.targetId), [B]);
  assert.deepEqual(actions(f), ['session_info', 'tab_list', 'tab_close', 'tab_list']); assert.equal(f.connections(), 1);
});
await fixture(async f => {
  const r = await f.run('close-owned-target', [A]);
  assert.equal(r.code, 9); assert.equal(r.fields.outcome, 'unknown'); assert.equal(r.fields.target, 'unverified');
  assert.deepEqual(actions(f), ['session_info', 'tab_list', 'tab_close', 'tab_list']);
  assert.deepEqual(f.tabs().map(t => t.targetId), [B]); assert.equal(f.connections(), 1);
}, { reply(req, res) { if (req.action === 'tab_list' && !res.data.tabs.some(t => t.targetId === A)) res.data = { confirmation_required: true }; } });
await fixture(async f => {
  const r = await f.run('close-owned-target', [A]);
  assert.equal(r.code, 0); assert.equal(r.fields.target, 'closed');
  assert.deepEqual(actions(f), ['session_info', 'tab_list', 'tab_close', 'tab_list']); assert.equal(f.connections(), 1);
}, { reply(req, res, socket) {
  if (req.action !== 'session_info') {
    setTimeout(() => socket.write(JSON.stringify(res) + '\n'), 1500);
    return false;
  }
} });
await fixture(async f => { const r = await f.run('close-owned-target', [A]); assert.equal(r.code, 0); assert.equal(r.fields.target, 'absent'); assert.deepEqual(actions(f), ['session_info', 'tab_list']); }, { tabs: [tab(B, 't2', true)] });
await fixture(async f => { assert.equal((await f.run('close-owned-target', [A])).code, 5); assert.deepEqual(actions(f), ['session_info', 'tab_list']); }, { reply(req, res) { if (req.action === 'tab_list') { res.success = false; res.error = 'failed'; delete res.data; } } });
for (const tabs of [[tab(A,'t1',true),tab(B,'t2',false,A)], [tab('t2','t1',true),tab(B,'t2')], [tab(A,'t1',true),tab(A.toLowerCase(),'t2')]]) {
  await fixture(async f => { assert.equal((await f.run('close-owned-target', [tabs[0].targetId])).code, 5); assert.ok(!actions(f).includes('tab_close')); }, { tabs });
}
await fixture(async f => { assert.equal((await f.run('discard-new-attach-target', [A, A])).code, 5); assert.ok(!actions(f).includes('tab_close')); });
await fixture(async f => { assert.equal((await f.run('discard-new-attach-target', [A, B])).code, 0); assert.deepEqual(f.tabs().map(t => t.targetId), [B]); });
await fixture(async f => { assert.equal((await f.run('discard-new-attach-target', ['', B])).code, 0); assert.deepEqual(f.tabs().map(t => t.targetId), [B]); });
for (const tabs of [[tab(B,'t2',true)], [tab(A,'t1',true),tab(B,'t2',true)], [tab(A,'t1'),tab(B,'t2')]]) {
  await fixture(async f => { assert.equal((await f.run('discard-new-attach-target', ['', B])).code, 5); assert.ok(!actions(f).includes('tab_close')); }, { tabs });
}
await fixture(async f => { const r = await f.run('clear-task-routes'); assert.equal(r.code, 9); assert.equal(r.fields.routes,'unverified'); assert.equal(actions(f).filter(x => x === 'unroute').length, 1); assert.equal(f.connections(), 1); }, { reply(req, res, socket) { if (req.action === 'unroute') { socket.destroy(); return false; } } });
await fixture(async f => { assert.equal((await f.run('close-owned-target',[A])).code,9); }, { reply(req,res) { if(req.action==='tab_close') res.data = {closed:true}; } });
for (const [operation,args] of [['bogus',[]],['close-daemon',['extra']],['close-owned-target',['']],['discard-new-attach-target',['']]]) {
  await fixture(async f => { assert.equal((await f.run(operation,args)).code,5); assert.equal(f.connections(),0); });
}
await fixture(async f => {
  const r = await f.run('clear-task-routes'); assert.equal(r.code, 9); assert.equal(r.fields.reason, 'DEADLINE');
  assert.equal(actions(f).filter(x => x === 'unroute').length, 1);
}, { reply(req) { if (req.action === 'unroute') return false; } });
for (const data of [{ tabs: null }, { tabs: [{targetId:A,tabId:'t1',active:true}] }, { tabs:[tab(A,'t1'),tab(B,'t1')] }, { tabs:[tab(A,['t1'],true)] }]) {
  await fixture(async f => { assert.equal((await f.run('close-owned-target', [A])).code,5); assert.ok(!actions(f).includes('tab_close')); }, { reply(req,res) { if(req.action==='tab_list') res.data=data; } });
}
await fixture(async f => { assert.equal((await f.run('discard-new-attach-target', [A, B])).fields.target, 'absent'); assert.ok(!actions(f).includes('tab_close')); }, { tabs: [tab(B, 't2', true)] });
await fixture(async f => { assert.equal((await f.run('close-owned-target',['t2'])).code,5); assert.ok(!actions(f).includes('tab_close')); });
await fixture(async f => { const r = await f.run('close-owned-target',['synthetic']); assert.equal(r.code,5); assert.equal(r.fields.target,'preserved'); assert.ok(!actions(f).includes('tab_close')); assert.deepEqual(f.tabs().map(t => t.targetId),['synthetic',B]); }, { tabs:[tab('synthetic','t1',true),tab(B,'t2')] });
await fixture(async f => { assert.equal((await f.run('close-owned-target',['synthetic'])).code,5); assert.ok(!actions(f).includes('tab_close')); }, { tabs:[tab('synthetic','t1',true),tab(B,'t2',false,'synthetic')] });
for (const operation of ['clear-task-routes','close-daemon']) {
  await fixture(async f => { assert.equal((await f.run(operation)).code,9); }, { reply(req,res) { if(req.action!=='session_info') res.data={ closed:false,unrouted:'some' }; } });
}
await fixture(async f => { assert.equal((await f.run('close-owned-target',[A])).code,9); assert.equal(f.connections(),1); }, { reply(req,res,socket) { if(req.action==='tab_close') {socket.write('{malformed}\n');return false;} } });
await fixture(async f => { assert.equal((await f.run('close-owned-target',[A])).code,9); assert.equal(actions(f).filter(x=>x==='tab_close').length,1); }, { reply(req,res) { if(req.action==='tab_list' && !res.data.tabs.some(t=>t.targetId===A)) res.data.tabs=[tab(A,'t1',true),tab(B,'t2')]; } });
await fixture(async f => { assert.equal((await f.run('close-daemon')).code,5); }, { reply(req,res) { delete res.success; } });
await fixture(async f => { assert.equal((await f.run('close-owned-target',['bad reference'])).code,5); assert.equal(f.connections(),0); });
console.log(`passed ${passed} administrative socket cases`);
