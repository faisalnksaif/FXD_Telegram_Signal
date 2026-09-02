import type { SignalEvent } from "./signalParser";

export interface StoredSignalEvent {
  seq: number;
  receivedAt: string;
  event: SignalEvent;
  isConsumed?: boolean; // SIGNAL_ALERT only: true once served to a poller at least once
}

// In-memory ring buffer of parsed signal events, served to the EA over HTTP.
// Not persisted across restarts by design: the EA only cares about events
// going forward from whatever `seq` it last saw, and a server restart wipes
// the buffer clean anyway so there's no backlog to worry about replaying.
//
// What guards against duplicate trades is `isConsumed`: a SIGNAL_ALERT starts
// unconsumed, and is marked consumed the first time it's served via since().
// If the EA restarts and re-polls from seq 0 while the server is still up
// (buffer intact), already-served alerts come back isConsumed:true so the EA
// knows not to reopen them.
export class SignalStore {
  private readonly maxEvents: number;
  private events: StoredSignalEvent[] = [];
  private nextSeq = 1;

  constructor(maxEvents = 1000) {
    this.maxEvents = maxEvents;
  }

  add(event: SignalEvent, receivedAt: string): StoredSignalEvent {
    const stored: StoredSignalEvent = { seq: this.nextSeq++, receivedAt, event };
    if (event.type === "SIGNAL_ALERT") {
      stored.isConsumed = false;
    }
    this.events.push(stored);
    if (this.events.length > this.maxEvents) {
      this.events = this.events.slice(this.events.length - this.maxEvents);
    }
    return stored;
  }

  // Returns events after `seq`. As a side effect, any SIGNAL_ALERT included
  // in the response is marked consumed (isConsumed: true), so it will never
  // be served as unconsumed again for the lifetime of this process.
  since(seq: number): StoredSignalEvent[] {
    const result = this.events.filter((e) => e.seq > seq);
    for (const e of result) {
      if (e.event.type === "SIGNAL_ALERT") {
        e.isConsumed = true;
      }
    }
    return result;
  }

  latestSeq(): number {
    return this.nextSeq - 1;
  }
}
