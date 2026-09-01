import type { SignalEvent } from "./signalParser";

export interface StoredSignalEvent {
  seq: number;
  receivedAt: string;
  event: SignalEvent;
}

// In-memory ring buffer of parsed signal events, served to the EA over HTTP.
// Not persisted across restarts by design: the EA only cares about events
// going forward from whatever `seq` it last saw.
export class SignalStore {
  private readonly maxEvents: number;
  private events: StoredSignalEvent[] = [];
  private nextSeq = 1;

  constructor(maxEvents = 1000) {
    this.maxEvents = maxEvents;
  }

  add(event: SignalEvent, receivedAt: string): StoredSignalEvent {
    const stored: StoredSignalEvent = { seq: this.nextSeq++, receivedAt, event };
    this.events.push(stored);
    if (this.events.length > this.maxEvents) {
      this.events = this.events.slice(this.events.length - this.maxEvents);
    }
    return stored;
  }

  since(seq: number): StoredSignalEvent[] {
    return this.events.filter((e) => e.seq > seq);
  }

  latestSeq(): number {
    return this.nextSeq - 1;
  }
}
