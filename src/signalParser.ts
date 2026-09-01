export type SignalEventType = "SIGNAL_ALERT" | "TP1_HIT" | "TP2_HIT" | "TP3_HIT" | "SL_HIT";

export interface SignalAlertEvent {
  type: "SIGNAL_ALERT";
  symbol: string;
  direction: "BUY" | "SELL";
  entry: number;
  sl: number;
  tp1: number;
  tp2: number;
  tp3: number;
}

export interface TpSlEvent {
  type: "TP1_HIT" | "TP2_HIT" | "TP3_HIT" | "SL_HIT";
  symbol: string;
  price: number;
}

export type SignalEvent = SignalAlertEvent | TpSlEvent;

const SIGNAL_ALERT_RE =
  /🎯 SIGNAL ALERT\s*\n+📊 (\S+) \|.*\n📈 Direction: (BUY|SELL)\s*\n+💰 Entry: ([\d.]+)\s*\n🛑 SL: ([\d.]+).*\n+✅ TP1: ([\d.]+).*\n✅ TP2: ([\d.]+).*\n✅ TP3: ([\d.]+)/u;

const TP_HIT_RE = /✅ TP([123]) HIT — (\S+)\s*\n+Take Profit reached at ([\d.]+)/u;
const SL_HIT_RE = /🛑 SL HIT — (\S+)\s*\n+Stop Loss triggered at ([\d.]+)/u;

export function parseSignalMessage(text: string): SignalEvent | null {
  const alertMatch = SIGNAL_ALERT_RE.exec(text);
  if (alertMatch) {
    const [, symbol, direction, entry, sl, tp1, tp2, tp3] = alertMatch;
    return {
      type: "SIGNAL_ALERT",
      symbol,
      direction: direction as "BUY" | "SELL",
      entry: Number(entry),
      sl: Number(sl),
      tp1: Number(tp1),
      tp2: Number(tp2),
      tp3: Number(tp3)
    };
  }

  const tpMatch = TP_HIT_RE.exec(text);
  if (tpMatch) {
    const [, tpNumber, symbol, price] = tpMatch;
    return {
      type: `TP${tpNumber}_HIT` as "TP1_HIT" | "TP2_HIT" | "TP3_HIT",
      symbol,
      price: Number(price)
    };
  }

  const slMatch = SL_HIT_RE.exec(text);
  if (slMatch) {
    const [, symbol, price] = slMatch;
    return { type: "SL_HIT", symbol, price: Number(price) };
  }

  return null;
}
