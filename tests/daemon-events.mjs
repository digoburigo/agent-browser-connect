import fs from 'node:fs';
import assert from 'node:assert/strict';
const [file, operation, ...args] = process.argv.slice(2);
const events = fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
if (operation === 'order') {
  const [oldTimeout, desiredTimeout] = args;
  const close = events.findIndex(event => event.kind === 'request' && event.action === 'close');
  assert(close >= 0, 'no socket close');
  assert(events.slice(0, close).some(event => event.kind === 'diagnostic' && event.active && event.timeout === oldTimeout), 'no saved-timeout diagnostic before close');
  const inactive = events.findIndex((event, index) => index > close && event.kind === 'diagnostic' && !event.active && event.timeout === oldTimeout);
  assert(inactive > close, 'no verified inactivity under saved timeout');
  const attach = events.findIndex((event, index) => index > close && event.kind === 'cli' && event.args.includes('--cdp'));
  assert(attach > inactive, 'replacement attached before verified inactivity');
  assert.equal(events[attach].timeout, desiredTimeout);
  for (const event of events.slice(close)) {
    if (event.kind === 'cli' && event.args.includes('--cdp')) assert.equal(event.timeout, desiredTimeout);
  }
} else {
  const requests = events.filter(event => event.kind === 'request' && event.action === operation);
  if (args[0] === 'absent') assert.equal(requests.length, 0, `unexpected socket ${operation}`);
  else {
    assert(requests.length > 0, `missing socket ${operation}`);
    if (args[0] !== 'present') assert.equal(requests.length, Number(args[0]));
    if (operation === 'close') {
      for (const request of requests) {
        assert.deepEqual(events.filter(event => event.kind === 'request' && event.connection === request.connection).map(event => event.action), ['session_info', 'close']);
      }
    }
  }
}
