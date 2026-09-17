import { writeFileSync } from "node:fs";
import { createServer } from "node:http";

const portFile = process.argv[2];
if (!portFile) {
  throw new Error("Expected a port-file path");
}

const page = `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>Containment test</title></head>
  <body>
    <h1>Containment test</h1>
    <a id="blank-link" href="/popup" target="_blank">Open tab</a>
    <button id="popup-button" type="button" onclick="window.open('/popup', '_blank', 'popup,width=420,height=320')">Open popup</button>
  </body>
</html>`;

const server = createServer((request, response) => {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  if (request.url === "/popup") {
    response.end("<!doctype html><title>Popup target</title><p>Popup target</p>");
    return;
  }
  response.end(page);
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Could not determine fixture port");
  }
  writeFileSync(portFile, `${address.port}\n`, { mode: 0o600 });
});

const stop = () => {
  server.close(() => process.exit(0));
};

process.on("SIGINT", stop);
process.on("SIGTERM", stop);
