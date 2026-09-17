const endpoint = process.argv[2];
if (!endpoint) {
  throw new Error("Expected a browser WebSocket endpoint");
}

const socket = new WebSocket(endpoint);
const pending = new Map();
let nextId = 1;

const opened = new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("CDP connection timed out")), 5000);
  socket.addEventListener("open", () => {
    clearTimeout(timeout);
    resolve();
  }, { once: true });
  socket.addEventListener("error", () => {
    clearTimeout(timeout);
    reject(new Error("CDP connection failed"));
  }, { once: true });
});

socket.addEventListener("message", (event) => {
  const message = JSON.parse(String(event.data));
  if (typeof message.id !== "number") {
    return;
  }
  const callback = pending.get(message.id);
  if (!callback) {
    return;
  }
  pending.delete(message.id);
  if (message.error) {
    callback.reject(new Error(message.error.message ?? "CDP command failed"));
    return;
  }
  callback.resolve(message.result ?? {});
});

const call = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId;
  nextId += 1;
  pending.set(id, { reject, resolve });
  socket.send(JSON.stringify({ id, method, params }));
});

await opened;
const { targetInfos = [] } = await call("Target.getTargets");
const pages = [];
for (const target of targetInfos) {
  if (target.type !== "page") {
    continue;
  }
  let windowId = null;
  try {
    const result = await call("Browser.getWindowForTarget", { targetId: target.targetId });
    windowId = result.windowId ?? null;
  } catch {
    // A target can disappear between Target.getTargets and the window lookup.
  }
  pages.push({
    openerId: target.openerId ?? null,
    targetId: target.targetId,
    url: target.url,
    windowId,
  });
}

pages.sort((left, right) => left.targetId.localeCompare(right.targetId));
console.log(JSON.stringify({ pages }));
socket.close();
