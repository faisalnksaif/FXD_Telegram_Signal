//+------------------------------------------------------------------+
//| FxdVipSignalEA.mq5                                                |
//| Polls the Node signal API (GET /api/signals?since=<seq>) over     |
//| WebRequest and executes/manages trades: 3-leg split, BE after     |
//| TP1, partial closes at TP1/TP2, full close at TP3/SL.             |
//|                                                                    |
//| IMPORTANT: add the API base URL to                                |
//|   Tools > Options > Expert Advisors > "Allow WebRequest for..."   |
//| or WebRequest calls will fail with error 4060.                    |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

input string InpApiBaseUrl       = "http://165.22.209.234:5000"; // e.g. https://your-server.example.com (no trailing slash)
input double InpLegLots          = 0.01;             // Lot size per leg (x3 legs opened per signal)
input ulong  InpMagicBase        = 990100;           // Magic number base (BUY/SELL offset added)
input int    InpPollMs           = 1000;             // Poll interval (ms)
input int    InpSlippagePoints   = 50;                // Max slippage in points
input int    InpHttpTimeoutMs    = 5000;              // WebRequest timeout (ms)

CTrade trade;
long   g_lastSeq = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(InpSlippagePoints);
   EventSetMillisecondTimer(InpPollMs);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   PollSignalApi();
  }

//+------------------------------------------------------------------+
void PollSignalApi()
  {
   string url = InpApiBaseUrl + "/api/signals?since=" + IntegerToString(g_lastSeq);
   string headers = "";
   char   postData[];
   char   result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("GET", url, headers, InpHttpTimeoutMs, postData, result, resultHeaders);
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         Print("FxdVipSignalEA: WebRequest blocked. Add ", InpApiBaseUrl,
               " to Tools > Options > Expert Advisors > Allow WebRequest for listed URL.");
      else
         Print("FxdVipSignalEA: WebRequest failed, error ", err);
      return;
     }

   if(status != 200)
     {
      Print("FxdVipSignalEA: signal API returned HTTP ", status);
      return;
     }

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   ProcessResponse(body);
  }

//+------------------------------------------------------------------+
// Response shape: {"events":[{"seq":N,"receivedAt":"...","event":{...}}, ...],"latestSeq":N}
void ProcessResponse(string body)
  {
   int eventsStart = StringFind(body, "\"events\":[");
   if(eventsStart < 0) return;
   eventsStart += StringLen("\"events\":[");

   int eventsEnd = FindMatchingBracket(body, eventsStart - 1, '[', ']');
   if(eventsEnd < 0) return;

   string eventsArray = StringSubstr(body, eventsStart, eventsEnd - eventsStart);
   if(StringLen(eventsArray) == 0) return;

   int pos = 0;
   int len = StringLen(eventsArray);
   while(pos < len)
     {
      int objStart = StringFind(eventsArray, "{", pos);
      if(objStart < 0) break;
      int objEnd = FindMatchingBracket(eventsArray, objStart, '{', '}');
      if(objEnd < 0) break;

      string entry = StringSubstr(eventsArray, objStart, objEnd - objStart + 1);
      ProcessEntry(entry);

      pos = objEnd + 1;
     }
  }

//+------------------------------------------------------------------+
// Finds the index of the closing bracket matching the opener at openIndex.
int FindMatchingBracket(const string &s, int openIndex, ushort openCh, ushort closeCh)
  {
   int depth = 0;
   int len = StringLen(s);
   for(int i = openIndex; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == openCh) depth++;
      else if(c == closeCh)
        {
         depth--;
         if(depth == 0) return i;
        }
     }
   return -1;
  }

//+------------------------------------------------------------------+
void ProcessEntry(string entry)
  {
   long seq = (long)JsonGetNumber(entry, "seq");
   if(seq <= g_lastSeq) return;

   int evStart = StringFind(entry, "\"event\":{");
   if(evStart < 0) return;
   evStart += StringLen("\"event\":");
   int evEnd = FindMatchingBracket(entry, evStart, '{', '}');
   if(evEnd < 0) return;
   string eventJson = StringSubstr(entry, evStart, evEnd - evStart + 1);

   // The server marks isConsumed:true on any SIGNAL_ALERT it has already
   // served before, so a restarted EA re-fetching the backlog from seq 0
   // never reopens a signal it (or a prior EA instance) already executed.
   bool alreadyConsumed = (JsonGetString(eventJson, "type") == "SIGNAL_ALERT")
                           && JsonGetBool(entry, "isConsumed");

   if(!alreadyConsumed)
      ProcessLine(eventJson);

   g_lastSeq = seq;
  }

//+------------------------------------------------------------------+
string JsonGetString(const string &json, const string key)
  {
   string pattern = "\"" + key + "\":\"";
   int start = StringFind(json, pattern);
   if(start < 0) return "";
   start += StringLen(pattern);
   int end = StringFind(json, "\"", start);
   if(end < 0) return "";
   return StringSubstr(json, start, end - start);
  }

//+------------------------------------------------------------------+
double JsonGetNumber(const string &json, const string key)
  {
   string pattern = "\"" + key + "\":";
   int start = StringFind(json, pattern);
   if(start < 0) return 0.0;
   start += StringLen(pattern);
   int end = start;
   int len = StringLen(json);
   while(end < len)
     {
      ushort c = StringGetCharacter(json, end);
      if(c == ',' || c == '}') break;
      end++;
     }
   string numStr = StringSubstr(json, start, end - start);
   return StringToDouble(numStr);
  }

//+------------------------------------------------------------------+
bool JsonGetBool(const string &json, const string key)
  {
   string pattern = "\"" + key + "\":";
   int start = StringFind(json, pattern);
   if(start < 0) return false;
   start += StringLen(pattern);
   return StringSubstr(json, start, 4) == "true";
  }

//+------------------------------------------------------------------+
ulong MagicFor(string direction)
  {
   return InpMagicBase + (direction == "SELL" ? 1 : 0);
  }

//+------------------------------------------------------------------+
void ProcessLine(string line)
  {
   string type = JsonGetString(line, "type");
   if(type == "") return;

   string symbol = JsonGetString(line, "symbol");
   if(symbol == "") return;

   if(!SymbolSelect(symbol, true))
     {
      Print("FxdVipSignalEA: cannot select symbol ", symbol);
      return;
     }

   if(type == "SIGNAL_ALERT")
     {
      string direction = JsonGetString(line, "direction");
      double sl  = JsonGetNumber(line, "sl");
      double tp1 = JsonGetNumber(line, "tp1");
      double tp2 = JsonGetNumber(line, "tp2");
      double tp3 = JsonGetNumber(line, "tp3");

      if(HasOpenPositionForLevels(symbol, MagicFor(direction), sl, tp1, tp2, tp3))
        {
         Print("FxdVipSignalEA: skipping duplicate SIGNAL_ALERT for ", symbol, " (already open)");
         return;
        }

      OpenSignal(symbol, direction, sl, tp1, tp2, tp3);
     }
   else if(type == "TP1_HIT" || type == "TP2_HIT" || type == "TP3_HIT" || type == "SL_HIT")
     {
      HandleOutcome(symbol, type);
     }
  }

//+------------------------------------------------------------------+
// Clamps a stop price so it respects the broker's minimum stop distance
// (SYMBOL_TRADE_STOPS_LEVEL/FREEZE_LEVEL) from the current market price,
// and rounds it to the symbol's tick size. isStopLoss selects which side
// of price the level must stay on for BUY vs SELL.
double NormalizeStopPrice(string symbol, ENUM_ORDER_TYPE orderType, double price, double level, bool isStopLoss)
  {
   if(level <= 0)
      return 0.0;

   int    stopsPoints  = (int)MathMax(SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                       SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   double point        = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minDistance   = stopsPoints * point;

   bool buySide = (orderType == ORDER_TYPE_BUY);
   // BUY: SL must be below price, TP above. SELL: SL above price, TP below.
   bool levelBelowPrice = (buySide && isStopLoss) || (!buySide && !isStopLoss);

   if(levelBelowPrice && price - level < minDistance)
      level = price - minDistance;
   else if(!levelBelowPrice && level - price < minDistance)
      level = price + minDistance;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      level = MathRound(level / tickSize) * tickSize;

   return NormalizeDouble(level, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
// True if an open position already exists for this symbol/magic whose SL
// and TP match this signal's levels — used to avoid reopening a signal
// that was already executed before an EA restart.
bool HasOpenPositionForLevels(string symbol, ulong magic, double sl, double tp1, double tp2, double tp3)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tol   = MathMax(point, 0.0000001) * 2;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;

      double posSl = PositionGetDouble(POSITION_SL);
      double posTp = PositionGetDouble(POSITION_TP);
      if(MathAbs(posSl - sl) > tol) continue;

      if(MathAbs(posTp - tp1) <= tol || MathAbs(posTp - tp2) <= tol || MathAbs(posTp - tp3) <= tol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
// Opens 3 legs (1 per TP target) at market, tagged with a comment that
// encodes the signal's entry timestamp so later legs from a NEWER signal
// on the same symbol are never confused with this one.
void OpenSignal(string symbol, string direction, double sl, double tp1, double tp2, double tp3)
  {
   ulong magic = MagicFor(direction);
   long signalTag = GetMicrosecondCount();
   string comment = "FXD-" + IntegerToString(signalTag);

   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double tps[3];
   tps[0] = tp1; tps[1] = tp2; tps[2] = tp3;

   for(int i = 0; i < 3; i++)
     {
      trade.SetExpertMagicNumber(magic);
      double price = (orderType == ORDER_TYPE_BUY)
                        ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(symbol, SYMBOL_BID);

      double legSl = NormalizeStopPrice(symbol, orderType, price, sl, true);
      double legTp = NormalizeStopPrice(symbol, orderType, price, tps[i], false);

      bool ok;
      if(orderType == ORDER_TYPE_BUY)
         ok = trade.Buy(InpLegLots, symbol, price, legSl, legTp, comment);
      else
         ok = trade.Sell(InpLegLots, symbol, price, legSl, legTp, comment);

      if(!ok)
         Print("FxdVipSignalEA: leg ", i + 1, " open failed for ", symbol, ": ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
// Finds the most recently opened batch of positions for this symbol
// (matched by comment tag shared across the 3 legs) and applies the
// outcome: partial close one leg per TP hit, move remainder to BE
// after TP1, close everything on TP3/SL.
void HandleOutcome(string symbol, string eventType)
  {
   string newestComment = "";
   long newestTag = -1;
   double entryPrice = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "FXD-") != 0) continue;

      long tag = (long)StringToInteger(StringSubstr(cmt, 4));
      if(tag > newestTag)
        {
         newestTag = tag;
         newestComment = cmt;
         entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }

   if(newestTag < 0)
     {
      Print("FxdVipSignalEA: no open FXD position found for ", symbol, " on ", eventType);
      return;
     }

   // Collect the legs belonging to the newest signal, sorted by open time (leg order = TP1,TP2,TP3).
   ulong legTickets[];
   ArrayResize(legTickets, 0);
   total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetString(POSITION_COMMENT) != newestComment) continue;

      int n = ArraySize(legTickets);
      ArrayResize(legTickets, n + 1);
      legTickets[n] = ticket;
     }

   SortTicketsByOpenTime(legTickets);

   if(eventType == "SL_HIT")
     {
      // Broker/native SL orders should have already closed these; this is just cleanup
      // in case any leg is still open (e.g. SL was manually moved to BE and didn't trigger).
      for(int i = 0; i < ArraySize(legTickets); i++)
         ClosePosition(legTickets[i]);
      return;
     }

   int legIndex = -1;
   if(eventType == "TP1_HIT") legIndex = 0;
   else if(eventType == "TP2_HIT") legIndex = 1;
   else if(eventType == "TP3_HIT") legIndex = 2;

   // Capture the hit leg's own TP price before closing it (TP2_HIT needs it
   // to move the remaining leg's SL up to the TP2 level).
   double hitLegTp = 0;
   if(legIndex >= 0 && legIndex < ArraySize(legTickets) && PositionSelectByTicket(legTickets[legIndex]))
      hitLegTp = PositionGetDouble(POSITION_TP);

   if(legIndex >= 0 && legIndex < ArraySize(legTickets))
      ClosePosition(legTickets[legIndex]);

   if(eventType == "TP3_HIT")
     {
      // Close anything left over defensively.
      for(int i = 0; i < ArraySize(legTickets); i++)
         ClosePosition(legTickets[i]);
      return;
     }

   if(eventType == "TP1_HIT")
     {
      // Move remaining legs' SL to break-even (entry price).
      for(int i = 0; i < ArraySize(legTickets); i++)
        {
         if(i == legIndex) continue;
         MoveToBreakEven(legTickets[i], entryPrice);
        }
     }
   else if(eventType == "TP2_HIT")
     {
      // Move remaining leg(s)' SL up to the TP2 level (locking in TP2 profit).
      for(int i = 0; i < ArraySize(legTickets); i++)
        {
         if(i == legIndex) continue;
         MoveToBreakEven(legTickets[i], hitLegTp);
        }
     }
  }

//+------------------------------------------------------------------+
void SortTicketsByOpenTime(ulong &tickets[])
  {
   int n = ArraySize(tickets);
   for(int i = 0; i < n - 1; i++)
     {
      for(int j = 0; j < n - i - 1; j++)
        {
         if(!PositionSelectByTicket(tickets[j])) continue;
         datetime tj = (datetime)PositionGetInteger(POSITION_TIME);
         if(!PositionSelectByTicket(tickets[j + 1])) continue;
         datetime tj1 = (datetime)PositionGetInteger(POSITION_TIME);
         if(tj > tj1)
           {
            ulong tmp = tickets[j];
            tickets[j] = tickets[j + 1];
            tickets[j + 1] = tmp;
           }
        }
     }
  }

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   if(!trade.PositionClose(ticket))
      Print("FxdVipSignalEA: failed to close ticket ", ticket, ": ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void MoveToBreakEven(ulong ticket, double newSlPrice)
  {
   if(!PositionSelectByTicket(ticket)) return;
   double tp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, newSlPrice, tp))
      Print("FxdVipSignalEA: failed to move ticket ", ticket, " to BE: ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
