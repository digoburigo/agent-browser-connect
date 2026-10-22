import net from 'node:net';
const env = process.env;
const [phase, session, ...args] = process.argv.slice(2);
const socket = net.createConnection({ host: '127.0.0.1', port: Number(env.MOCK_FIXTURE_PORT) });
const deadline = setTimeout(() => { socket.destroy(); process.exitCode = 1; }, 3000);
let reply = '';
socket.on('connect', () => socket.write(JSON.stringify({
  phase, session, args, socketDir: env.MOCK_SOCKET_DIR, stateDir: env.MOCK_STATE_DIR,
  commandLog: env.MOCK_LOG, mode: env.MOCK_MODE || 'success', timeout: env.AGENT_BROWSER_IDLE_TIMEOUT_MS ?? 'unset'
}) + '\n'));
socket.on('data', chunk => { reply += chunk; });
socket.on('error', error => { console.error(error); process.exitCode = 1; });
socket.on('close', () => {
  clearTimeout(deadline);
  if (reply !== 'ok\n') { console.error(reply || 'registration failed'); process.exitCode = 1; }
});
