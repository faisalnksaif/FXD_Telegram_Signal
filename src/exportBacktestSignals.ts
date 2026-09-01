import { readFile, mkdir, writeFile } from "fs/promises";
import path from "path";
import { config } from "./config";
import { parseSignalMessage } from "./signalParser";
import type { CapturedMessage } from "./messageStore";

// Reads the history dump produced by fetchHistory.ts, extracts SIGNAL_ALERT
// events only (TP/SL hits are simulated from price in the tester), and
// writes a chronologically-sorted CSV for the MT5 backtest EA to read from
// MQL5/Files/.
const HISTORY_PATH = path.join(path.dirname(config.dataFilePath), "history-fxd-vip.jsonl");
const OUTPUT_PATH = path.join(path.dirname(config.dataFilePath), "backtest-signals.csv");

interface Row {
  epochSeconds: number;
  symbol: string;
  direction: "BUY" | "SELL";
  entry: number;
  sl: number;
  tp1: number;
  tp2: number;
  tp3: number;
}

async function main(): Promise<void> {
  const raw = await readFile(HISTORY_PATH, "utf-8");
  const lines = raw.split("\n").filter((l) => l.trim().length > 0);

  const rows: Row[] = [];
  for (const line of lines) {
    const msg = JSON.parse(line) as CapturedMessage;
    const event = parseSignalMessage(msg.text);
    if (!event || event.type !== "SIGNAL_ALERT") continue;

    rows.push({
      epochSeconds: Math.floor(new Date(msg.receivedAt).getTime() / 1000),
      symbol: event.symbol,
      direction: event.direction,
      entry: event.entry,
      sl: event.sl,
      tp1: event.tp1,
      tp2: event.tp2,
      tp3: event.tp3
    });
  }

  rows.sort((a, b) => a.epochSeconds - b.epochSeconds);

  const header = "epoch,symbol,direction,entry,sl,tp1,tp2,tp3";
  const csvLines = rows.map(
    (r) =>
      `${r.epochSeconds},${r.symbol},${r.direction},${r.entry},${r.sl},${r.tp1},${r.tp2},${r.tp3}`
  );

  await mkdir(path.dirname(OUTPUT_PATH), { recursive: true });
  await writeFile(OUTPUT_PATH, [header, ...csvLines].join("\n") + "\n", "utf-8");

  console.log(`Wrote ${rows.length} SIGNAL_ALERT rows to ${OUTPUT_PATH}`);
  if (rows.length > 0) {
    console.log(
      `Range: ${new Date(rows[0].epochSeconds * 1000).toISOString()} -> ${new Date(
        rows[rows.length - 1].epochSeconds * 1000
      ).toISOString()}`
    );
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
