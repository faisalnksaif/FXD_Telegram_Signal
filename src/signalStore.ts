import fs from "fs";
import path from "path";
import type { SignalEvent } from "./signalParser";

export interface StoredSignalEvent {
  seq: number;
  receivedAt: string;
  event: SignalEvent;
  isConsumed?: boolean; // SIGNAL_ALERT only: true once served to a poller at least once
}

// In-memory ring buffer of parsed signal events, served to the EA over HTTP.
// The event log itself is not persisted across restarts (the EA only cares
// about events going forward from whatever `seq` it last saw). But which
// SIGNAL_ALERT was last consumed *is* persisted to disk, so that even if
// both the EA and this server restart, a stale/backlog SIGNAL_ALERT is never
// served as fresh and re-opened as a duplicate trade.
export class SignalStore {
  private readonly maxEvents: number;
  private readonly consumedStatePath: string | null;
  private events: StoredSignalEvent[] = [];
  private nextSeq = 1;
  // symbol -> fingerprint of the last SIGNAL_ALERT served to a poller
  private lastConsumedAlert: Record<string, string> = {};

  constructor(maxEvents = 1000, consumedStatePath: string | null = null) {
    this.maxEvents = maxEvents;
    this.consumedStatePath = consumedStatePath;
    this.loadConsumedState();
  }

  add(event: SignalEvent, receivedAt: string): StoredSignalEvent {
    const stored: StoredSignalEvent = { seq: this.nextSeq++, receivedAt, event };
    if (event.type === "SIGNAL_ALERT") {
      stored.isConsumed = this.lastConsumedAlert[event.symbol] === alertFingerprint(event);
    }
    this.events.push(stored);
    if (this.events.length > this.maxEvents) {
      this.events = this.events.slice(this.events.length - this.maxEvents);
    }
    return stored;
  }

  // Returns events after `seq`. As a side effect, any SIGNAL_ALERT included
  // in the response is marked consumed (isConsumed: true) and persisted, so
  // it will never be served as unconsumed again, even after a restart.
  since(seq: number): StoredSignalEvent[] {
    const result = this.events.filter((e) => e.seq > seq);
    let changed = false;
    for (const e of result) {
      if (e.event.type === "SIGNAL_ALERT" && !e.isConsumed) {
        e.isConsumed = true;
        this.lastConsumedAlert[e.event.symbol] = alertFingerprint(e.event);
        changed = true;
      }
    }
    if (changed) this.saveConsumedState();
    return result;
  }

  latestSeq(): number {
    return this.nextSeq - 1;
  }

  private loadConsumedState(): void {
    if (!this.consumedStatePath) return;
    try {
      const raw = fs.readFileSync(this.consumedStatePath, "utf8");
      this.lastConsumedAlert = JSON.parse(raw);
    } catch {
      this.lastConsumedAlert = {};
    }
  }

  private saveConsumedState(): void {
    if (!this.consumedStatePath) return;
    try {
      fs.mkdirSync(path.dirname(this.consumedStatePath), { recursive: true });
      fs.writeFileSync(this.consumedStatePath, JSON.stringify(this.lastConsumedAlert));
    } catch (err) {
      console.error("SignalStore: failed to persist consumed state:", err);
    }
  }
}

function alertFingerprint(event: Extract<SignalEvent, { type: "SIGNAL_ALERT" }>): string {
  return [event.symbol, event.direction, event.entry, event.sl, event.tp1, event.tp2, event.tp3].join("|");
}
