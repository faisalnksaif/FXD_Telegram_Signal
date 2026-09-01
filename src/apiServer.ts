import http from "http";
import type { SignalStore } from "./signalStore";

// GET /api/signals?since=<seq> -> { events: [...], latestSeq: number }
// The EA polls this with `since` set to the highest seq it has already processed.
export function createApiServer(store: SignalStore, port: number): http.Server {
  const server = http.createServer((req, res) => {
    if (!req.url || req.method !== "GET") {
      res.writeHead(404).end();
      return;
    }

    const url = new URL(req.url, "http://localhost");
    if (url.pathname !== "/api/signals") {
      res.writeHead(404).end();
      return;
    }

    const sinceParam = url.searchParams.get("since");
    const since = sinceParam ? Number(sinceParam) : 0;
    const events = Number.isFinite(since) ? store.since(since) : store.since(0);

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ events, latestSeq: store.latestSeq() }));
  });

  server.listen(port, () => {
    console.log(`Signal API listening on port ${port}`);
  });

  return server;
}
