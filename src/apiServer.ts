import http from "http";
import type { SignalStore } from "./signalStore";
import type { SignalEvent } from "./signalParser";

function isValidSignalEvent(body: unknown): body is SignalEvent {
  if (!body || typeof body !== "object") return false;
  const b = body as Record<string, unknown>;
  if (typeof b.symbol !== "string" || !b.symbol) return false;

  if (b.type === "SIGNAL_ALERT") {
    return (
      (b.direction === "BUY" || b.direction === "SELL") &&
      typeof b.entry === "number" &&
      typeof b.sl === "number" &&
      typeof b.tp1 === "number" &&
      typeof b.tp2 === "number" &&
      typeof b.tp3 === "number"
    );
  }

  if (b.type === "TP1_HIT" || b.type === "TP2_HIT" || b.type === "TP3_HIT" || b.type === "SL_HIT") {
    return typeof b.price === "number";
  }

  return false;
}

// GET /api/signals?since=<seq> -> { events: [...], latestSeq: number }
// The EA polls this with `since` set to the highest seq it has already processed.
//
// POST /api/signals/test -> manually inject a SignalEvent for testing the EA
// without needing a real Telegram message. Body is a SignalEvent JSON object,
// e.g. {"type":"SIGNAL_ALERT","symbol":"EURUSD","direction":"BUY","entry":1.1,"sl":1.09,"tp1":1.105,"tp2":1.11,"tp3":1.115}
export function createApiServer(store: SignalStore, port: number): http.Server {
  const server = http.createServer((req, res) => {
    if (!req.url) {
      res.writeHead(404).end();
      return;
    }

    const url = new URL(req.url, "http://localhost");

    if (req.method === "GET" && url.pathname === "/api/signals") {
      const sinceParam = url.searchParams.get("since");
      const since = sinceParam ? Number(sinceParam) : 0;
      const events = Number.isFinite(since) ? store.since(since) : store.since(0);

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ events, latestSeq: store.latestSeq() }));
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/signals/test") {
      let raw = "";
      req.on("data", (chunk) => {
        raw += chunk;
      });
      req.on("end", () => {
        let body: unknown;
        try {
          body = JSON.parse(raw);
        } catch {
          res.writeHead(400, { "Content-Type": "application/json" }).end(JSON.stringify({ error: "invalid JSON" }));
          return;
        }

        if (!isValidSignalEvent(body)) {
          res.writeHead(400, { "Content-Type": "application/json" }).end(JSON.stringify({ error: "invalid signal event" }));
          return;
        }

        const stored = store.add(body, new Date().toISOString());
        console.log(`[test] Injected signal event #${stored.seq}: ${stored.event.type} ${stored.event.symbol}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(stored));
      });
      return;
    }

    res.writeHead(404).end();
  });

  server.listen(port, () => {
    console.log(`Signal API listening on port ${port}`);
  });

  return server;
}
