//+------------------------------------------------------------------+
//| FxdVipBacktestEA.mq5                                              |
//| Strategy Tester EA for replaying captured FXD VIP signals.        |
//|                                                                    |
//| The live EA (FxdVipSignalEA.mq5) polls a Node server over         |
//| WebRequest for SIGNAL_ALERT / TPx_HIT / SL_HIT events. The tester |
//| has no network access, so this EA instead reads a CSV of          |
//| SIGNAL_ALERT rows exported by `npm run export:backtest`           |
//| (data/backtest-signals.csv -> copy into MQL5/Files/) and          |
//| simulates TP1/TP2/TP3/SL hits itself from historical bid/ask,     |
//| reproducing the same 3-leg / partial-close / break-even logic.    |
//|                                                                    |
//| CSV format (header row required):                                 |
//|   epoch,symbol,direction,entry,sl,tp1,tp2,tp3                     |
//|                                                                    |
//| Setup:                                                             |
//|   1. npm run export:backtest   (writes data/backtest-signals.csv) |
//|   2. Copy that file to <Terminal Data Folder>/MQL5/Files/          |
//|      (or set InpSignalFile to a full path under Files/)           |
//|   3. Open Strategy Tester, symbol XAUUSD (or whatever the CSV     |
//|      contains), pick a date range covering the CSV's timestamps,  |
//|      model "Every tick based on real ticks" for accurate TP/SL    |
//|      touches, attach this EA, run.                                |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

input string InpSignalFile   = "backtest-signals.csv"; // CSV file under MQL5/Files/
input double InpLegLots      = 0.01;                    // Lot size per leg (x3 legs per signal)
input ulong  InpMagicBase    = 990200;                  // Magic number base (BUY/SELL offset added)
input int    InpSlippagePoints = 50;                    // Max slippage in points

CTrade trade;

struct SignalRow
  {
   datetime time;
   string   symbol;
   string   direction;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   double   tp3;
   bool     fired;
  };

SignalRow g_rows[];

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(InpSlippagePoints);
   if(!LoadSignals(InpSignalFile))
     {
      Print("FxdVipBacktestEA: failed to load signal file ", InpSignalFile);
      return INIT_FAILED;
     }
   PrintFormat("FxdVipBacktestEA: loaded %d signals from %s", ArraySize(g_rows), InpSignalFile);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
bool LoadSignals(string filename)
  {
   int handle = FileOpen(filename, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("FxdVipBacktestEA: cannot open ", filename, ", error ", GetLastError());
      return false;
     }

   // Header row.
   if(!FileIsEnding(handle))
     {
      for(int i = 0; i < 8 && !FileIsLineEnding(handle); i++)
         FileReadString(handle);
     }

   ArrayResize(g_rows, 0);
   while(!FileIsEnding(handle))
     {
      string epochStr = FileReadString(handle);
      if(StringLen(epochStr) == 0) break;

      SignalRow row;
      row.time      = (datetime)StringToInteger(epochStr);
      row.symbol    = FileReadString(handle);
      row.direction = FileReadString(handle);
      row.entry     = StringToDouble(FileReadString(handle));
      row.sl        = StringToDouble(FileReadString(handle));
      row.tp1       = StringToDouble(FileReadString(handle));
      row.tp2       = StringToDouble(FileReadString(handle));
      row.tp3       = StringToDouble(FileReadString(handle));
      row.fired     = false;

      int n = ArraySize(g_rows);
      ArrayResize(g_rows, n + 1);
      g_rows[n] = row;
     }

   FileClose(handle);
   return ArraySize(g_rows) > 0;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   // Fire any signals whose timestamp has been reached.
   for(int i = 0; i < ArraySize(g_rows); i++)
     {
      if(g_rows[i].fired) continue;
      if(now < g_rows[i].time) continue;

      if(g_rows[i].symbol == _Symbol)
         OpenSignal(g_rows[i].symbol, g_rows[i].direction, g_rows[i].sl,
                    g_rows[i].tp1, g_rows[i].tp2, g_rows[i].tp3, g_rows[i].time);

      g_rows[i].fired = true;
     }

   ManageOpenPositions();
  }

//+------------------------------------------------------------------+
ulong MagicFor(string direction)
  {
   return InpMagicBase + (direction == "SELL" ? 1 : 0);
  }

//+------------------------------------------------------------------+
// Opens 3 legs (1 per TP target), tagged with a comment encoding the
// signal's own timestamp so each signal's legs are managed independently.
void OpenSignal(string symbol, string direction, double sl, double tp1, double tp2, double tp3, datetime signalTime)
  {
   ulong magic = MagicFor(direction);
   string comment = "FXDBT-" + IntegerToString((long)signalTime);

   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double tps[3];
   tps[0] = tp1; tps[1] = tp2; tps[2] = tp3;

   for(int i = 0; i < 3; i++)
     {
      trade.SetExpertMagicNumber(magic);
      double price = (orderType == ORDER_TYPE_BUY)
                        ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(symbol, SYMBOL_BID);

      bool ok;
      if(orderType == ORDER_TYPE_BUY)
         ok = trade.Buy(InpLegLots, symbol, price, sl, tps[i], comment);
      else
         ok = trade.Sell(InpLegLots, symbol, price, sl, tps[i], comment);

      if(!ok)
         PrintFormat("FxdVipBacktestEA: leg %d open failed for %s at %s: %s",
                      i + 1, symbol, TimeToString(signalTime), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
// Simulates TP1/TP2/TP3 detection from live bid/ask (SL is handled by the
// native stop already attached to each leg). Each signal batch (identified
// by comment tag) is checked independently: close one leg per TP level
// crossed, move remaining legs to break-even after TP1.
void ManageOpenPositions()
  {
   string tags[];
   ArrayResize(tags, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "FXDBT-") != 0) continue;

      bool known = false;
      for(int j = 0; j < ArraySize(tags); j++)
         if(tags[j] == cmt) { known = true; break; }

      if(!known)
        {
         int n = ArraySize(tags);
         ArrayResize(tags, n + 1);
         tags[n] = cmt;
        }
     }

   for(int t = 0; t < ArraySize(tags); t++)
      ManageBatch(tags[t]);
  }

//+------------------------------------------------------------------+
void ManageBatch(string comment)
  {
   ulong legTickets[];
   ArrayResize(legTickets, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetString(POSITION_COMMENT) != comment) continue;

      int n = ArraySize(legTickets);
      ArrayResize(legTickets, n + 1);
      legTickets[n] = ticket;
     }

   int count = ArraySize(legTickets);
   if(count == 0) return;

   SortTicketsByOpenTime(legTickets);

   if(!PositionSelectByTicket(legTickets[0])) return;
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Leg order = TP1, TP2, TP3 (opened in that order in OpenSignal).
   for(int legIndex = 0; legIndex < count; legIndex++)
     {
      ulong ticket = legTickets[legIndex];
      if(!PositionSelectByTicket(ticket)) continue;

      double tp = PositionGetDouble(POSITION_TP);
      if(tp <= 0) continue;

      bool hit = isBuy ? (currentPrice >= tp) : (currentPrice <= tp);
      if(!hit) continue;

      double hitLegTp = tp;

      ClosePosition(ticket);

      // After TP1 (legIndex 0), move the remaining legs' SL to break-even (entry).
      // After TP2 (legIndex 1), move the remaining leg's SL up to the TP2 level.
      if(legIndex == 0)
        {
         for(int k = 0; k < count; k++)
           {
            if(k == legIndex) continue;
            MoveToBreakEven(legTickets[k], entryPrice);
           }
        }
      else if(legIndex == 1)
        {
         for(int k = 0; k < count; k++)
           {
            if(k == legIndex) continue;
            MoveToBreakEven(legTickets[k], hitLegTp);
           }
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
      Print("FxdVipBacktestEA: failed to close ticket ", ticket, ": ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void MoveToBreakEven(ulong ticket, double newSlPrice)
  {
   if(!PositionSelectByTicket(ticket)) return;
   double tp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, newSlPrice, tp))
      Print("FxdVipBacktestEA: failed to move ticket ", ticket, " to BE: ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
