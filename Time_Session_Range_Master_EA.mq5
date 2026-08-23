//+------------------------------------------------------------------+
//|                               Time_Session_Range_Master_EA.mq5   |
//|                    Pure ICT Session Range Strategy - High Perf   |
//+------------------------------------------------------------------+
#property copyright "Senior Quantitative Developer"
#property link      ""
#property version   "5.20"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input double InpRiskPercent       = 2.0;       // Risk Per Trade (%)
input double InpMinLots           = 0.01;      // Minimum Lots
input int    InpBrokerOffsetHours = 5;         // Broker UTC Offset (e.g., 5 for GMT+3/UTC-5 NY)
input bool   InpNoWeekends        = true;      // Halt Trading Over Weekends
input ulong  InpMagicNumber       = 1337001;   // Magic Number

input string InpDividerTP         = "--- Target/RR Settings ---";
input double InpModel1TargetR     = 1.0;       // Model 1: Take Profit (R)
input double InpModel2TargetR     = 1.0;       // Model 2: Take Profit (R)

input string InpDivider1          = "--- Alert Settings ---";
input bool   InpEnableTelegram    = false;     // Enable Telegram Alerts
input string InpTelegramToken     = "";        // Telegram Bot Token
input string InpTelegramChatID    = "";        // Telegram Chat ID
input bool   InpEnableLineNotify  = false;     // Enable LINE Notify
input string InpLineToken         = "";        // LINE Notify Token

//--- Enums
enum ENUM_STATE 
{ 
   STATE_IDLE, 
   STATE_PENDING_LIMIT, 
   STATE_BREAKOUT_SHIFTED, 
   STATE_ACTIVE_FILLED, 
   STATE_WAITING_SWEEP_CONFIRMATION, 
   STATE_SWEEP_REVERSAL, 
   STATE_CLOSED, 
   STATE_SHUTDOWN 
};

enum ENUM_SESSION_ID 
{ 
   SESSION_NY_PM, 
   SESSION_ASIA, 
   SESSION_LONDON, 
   SESSION_NY_AM 
};

//--- Structs
struct SessionBlock 
{
   ENUM_SESSION_ID id;
   string          name;
   int             startHourUTC5;
   int             startMinUTC5;
   int             endHourUTC5;
   int             endMinUTC5;
   
   bool            isActive;
   bool            wasActive;
   
   double          high;
   double          low;
   double          open;
   double          close;
   double          range;
   double          midline;
   datetime        sessionStartTime;
   datetime        sessionEndTime;
};

struct ExecutionPlan 
{
   ENUM_STATE      state;
   string          modelName;
   bool            isLong;
   
   double          boundaryHigh;
   double          boundaryLow;
   double          midline;
   double          rangeSize;
   
   double          sweepHighExt;
   double          sweepLowExt;
   
   double          entryPrice;
   double          slPrice;
   double          tpPrice;
   
   ulong           pendingTicket;
   ulong           positionTicket;
};

//--- Global Objects
CTrade         g_Trade;
CSymbolInfo    g_Symbol;
SessionBlock   g_Sessions[4];
ExecutionPlan  g_Plan;

int            g_LastDay = -1;
datetime       g_LastBarTime = 0;

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                |
//+------------------------------------------------------------------+
void SendAlert(string msg)
{
   Print(msg);
   
   if(InpEnableTelegram && StringLen(InpTelegramToken) > 0 && StringLen(InpTelegramChatID) > 0)
   {
      string url = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
      string headers = "Content-Type: application/json\r\n";
      string msgEsc = msg;
      StringReplace(msgEsc, "\n", "\\n");
      StringReplace(msgEsc, "\r", "");
      StringReplace(msgEsc, "\"", "\\\"");
      string payload = "{\"chat_id\":\"" + InpTelegramChatID + "\",\"text\":\"" + msgEsc + "\"}";
      
      char post[], result[];
      string resHeaders;
      StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(post, ArraySize(post)-1);
      
      int res = WebRequest("POST", url, headers, 5000, post, result, resHeaders);
      if(res != 200) Print("Telegram Alert Error: ", res);
   }
   
   if(InpEnableLineNotify && StringLen(InpLineToken) > 0)
   {
      string url = "https://notify-api.line.me/api/notify";
      string headers = "Authorization: Bearer " + InpLineToken + "\r\n";
      headers += "Content-Type: application/x-www-form-urlencoded\r\n";
      
      string payload = "message=" + msg;
      
      char post[], result[];
      string resHeaders;
      StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(post, ArraySize(post)-1);
      
      int res = WebRequest("POST", url, headers, 5000, post, result, resHeaders);
      if(res != 200) Print("LINE Alert Error: ", res);
   }
}





double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

bool IsStopsLevelViolated(ENUM_ORDER_TYPE type, double entry, double &adjustedEntry)
{
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   double minLevel = MathMax(stopsLevel, freezeLevel);
   
   g_Symbol.RefreshRates();
   
   if(type == ORDER_TYPE_BUY_LIMIT)
   {
      double minAllowed = g_Symbol.Ask() - minLevel;
      if(entry > minAllowed)
      {
         adjustedEntry = minAllowed;
         return true;
      }
   }
   else if(type == ORDER_TYPE_SELL_LIMIT)
   {
      double minAllowed = g_Symbol.Bid() + minLevel;
      if(entry < minAllowed)
      {
         adjustedEntry = minAllowed;
         return true;
      }
   }
   return false;
}

double CalculateLotSize(double entry, double sl)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);
   double slDist = MathAbs(entry - sl);
   
   if(slDist == 0) return InpMinLots;
   
   double tickSize = g_Symbol.TickSize();
   double tickValue = g_Symbol.TickValue();
   if(tickSize == 0 || tickValue == 0) return InpMinLots;
   
   double lossPerLot = (slDist / tickSize) * tickValue;
   if(lossPerLot == 0) return InpMinLots;
   
   double lots = riskMoney / lossPerLot;
   
   double minL = g_Symbol.LotsMin();
   double maxL = g_Symbol.LotsMax();
   double step = g_Symbol.LotsStep();
   
   lots = MathRound(lots / step) * step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   
   return lots;
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == g_Trade.RequestMagic())
      {
         g_Trade.OrderDelete(ticket);
      }
   }
   g_Plan.pendingTicket = 0;
}

bool HasActivePosition(ulong &ticket)
{
   if(ticket > 0)
   {
      if(PositionSelectByTicket(ticket)) return true;
   }
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == g_Trade.RequestMagic())
      {
         ticket = pt;
         return true;
      }
   }
   ticket = 0;
   return false;
}

bool HasActiveOrder(ulong ticket)
{
   return OrderSelect(ticket);
}

//+------------------------------------------------------------------+
//| SESSION ENGINE                                                   |
//+------------------------------------------------------------------+
void InitSessions()
{
   g_Sessions[0].id = SESSION_NY_PM; g_Sessions[0].name = "NY PM";
   g_Sessions[0].startHourUTC5 = 12; g_Sessions[0].startMinUTC5 = 30;
   g_Sessions[0].endHourUTC5 = 15;   g_Sessions[0].endMinUTC5 = 0;
   
   g_Sessions[1].id = SESSION_ASIA;  g_Sessions[1].name = "ASIAN";
   g_Sessions[1].startHourUTC5 = 19; g_Sessions[1].startMinUTC5 = 0;
   g_Sessions[1].endHourUTC5 = 23;   g_Sessions[1].endMinUTC5 = 0;
   
   g_Sessions[2].id = SESSION_LONDON; g_Sessions[2].name = "LONDON";
   g_Sessions[2].startHourUTC5 = 1;  g_Sessions[2].startMinUTC5 = 0;
   g_Sessions[2].endHourUTC5 = 4;    g_Sessions[2].endMinUTC5 = 0;
   
   g_Sessions[3].id = SESSION_NY_AM; g_Sessions[3].name = "NY AM";
   g_Sessions[3].startHourUTC5 = 7;  g_Sessions[3].startMinUTC5 = 30;
   g_Sessions[3].endHourUTC5 = 10;   g_Sessions[3].endMinUTC5 = 0;
}

bool IsInsideSession(datetime time, int sH, int sM, int eH, int eM)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);
   
   int brokerMin = dt.hour * 60 + dt.min;
   int utc5Min = brokerMin - (InpBrokerOffsetHours * 60);
   while(utc5Min < 0) utc5Min += 1440;
   while(utc5Min >= 1440) utc5Min -= 1440;
   
   int startM = sH * 60 + sM;
   int endM = eH * 60 + eM;
   
   if(startM < endM)
   {
      return (utc5Min >= startM && utc5Min < endM);
   }
   else
   {
      return (utc5Min >= startM || utc5Min < endM);
   }
}

void InitPendingOrder(SessionBlock &refSess)
{
   if(refSess.range <= 0) return;
   
   g_Plan.boundaryHigh = refSess.high;
   g_Plan.boundaryLow  = refSess.low;
   g_Plan.midline      = refSess.midline;
   g_Plan.rangeSize    = refSess.range;
   
   bool isBullish = (refSess.close >= refSess.midline);
   double expMultiplier = InpModel1TargetR;
   
   g_Plan.isLong = isBullish;
   if(isBullish)
   {
      g_Plan.entryPrice = NormalizePrice(refSess.midline);
      g_Plan.slPrice    = NormalizePrice(refSess.low);
      g_Plan.tpPrice    = NormalizePrice(refSess.high + (refSess.range * expMultiplier));
   }
   else
   {
      g_Plan.entryPrice = NormalizePrice(refSess.midline);
      g_Plan.slPrice    = NormalizePrice(refSess.high);
      g_Plan.tpPrice    = NormalizePrice(refSess.low - (refSess.range * expMultiplier));
   }
   
   double adjEntry = g_Plan.entryPrice;
   ENUM_ORDER_TYPE oType = isBullish ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   
   IsStopsLevelViolated(oType, g_Plan.entryPrice, adjEntry);
   double lots = CalculateLotSize(adjEntry, g_Plan.slPrice);
   
   CancelAllPendingOrders();
   g_Symbol.RefreshRates();
   
   if(g_Trade.OrderOpen(_Symbol, oType, lots, 0.0, adjEntry, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Target"))
   {
      g_Plan.state = STATE_PENDING_LIMIT;
      g_Plan.pendingTicket = g_Trade.ResultOrder();
      g_Plan.modelName = "Model 1: Pending";
      
      g_Plan.sweepHighExt = refSess.high;
      g_Plan.sweepLowExt  = refSess.low;
      
      string oTypeStr = isBullish ? "BUY LIMIT" : "SELL LIMIT";
      string txt = StringFormat("⏳ [Model 1: Pending] %s %s\nEntry: %.5f\nSL: %.5f\nTP: %.5f", oTypeStr, _Symbol, adjEntry, g_Plan.slPrice, g_Plan.tpPrice);
      SendAlert(txt);
   }
}

void UpdateSessionTracking(datetime currentServerTime)
{
   MqlDateTime dt;
   TimeToStruct(currentServerTime, dt);
   
   if(dt.day != g_LastDay)
   {
      g_LastDay = dt.day;
      SendAlert(StringFormat("📅 [NEW DAY] Daily stats reset. Date: %d-%02d-%02d", dt.year, dt.mon, dt.day));
   }
   
   int brokerMin = dt.hour * 60 + dt.min;
   int utc5Min = brokerMin - (InpBrokerOffsetHours * 60);
   while(utc5Min < 0) utc5Min += 1440;
   while(utc5Min >= 1440) utc5Min -= 1440;
   
   if(InpNoWeekends)
   {
      if(dt.day_of_week == 6 || (dt.day_of_week == 0 && utc5Min < (17 * 60)))
      {
         if(g_Plan.state != STATE_SHUTDOWN)
         {
             CancelAllPendingOrders();
             g_Plan.state = STATE_SHUTDOWN;
         }
         return;
      }
   }
      
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 2, rates) < 2) return;
   
   double currentHigh  = rates[0].high;
   double currentLow   = rates[0].low;
   double currentOpen  = rates[0].open;
   double currentClose = rates[0].close;
   
   for(int i = 0; i < 4; i++)
   {
      bool inSession = IsInsideSession(currentServerTime,
                                        g_Sessions[i].startHourUTC5, g_Sessions[i].startMinUTC5,
                                        g_Sessions[i].endHourUTC5,   g_Sessions[i].endMinUTC5);
      g_Sessions[i].wasActive = g_Sessions[i].isActive;
      g_Sessions[i].isActive  = inSession;
      
      if(g_Sessions[i].isActive && !g_Sessions[i].wasActive)
      {
         g_Sessions[i].high             = currentHigh;
         g_Sessions[i].low              = currentLow;
         g_Sessions[i].open             = currentOpen;
         g_Sessions[i].close            = currentClose;
         g_Sessions[i].sessionStartTime = currentServerTime;
      }
      
      if(g_Sessions[i].isActive)
      {
         g_Sessions[i].high    = MathMax(g_Sessions[i].high, currentHigh);
         g_Sessions[i].low     = MathMin(g_Sessions[i].low, currentLow);
         g_Sessions[i].close   = currentClose;
         g_Sessions[i].range   = g_Sessions[i].high - g_Sessions[i].low;
         g_Sessions[i].midline = g_Sessions[i].low + (0.5 * g_Sessions[i].range);
      }
      
      if(!g_Sessions[i].isActive && g_Sessions[i].wasActive)
      {
         g_Sessions[i].sessionEndTime = currentServerTime;
         
         if(g_Sessions[i].id == SESSION_NY_PM || g_Sessions[i].id == SESSION_ASIA || g_Sessions[i].id == SESSION_LONDON)
         {
            g_Plan.state = STATE_CLOSED;
            InitPendingOrder(g_Sessions[i]);
         }
         else if(g_Sessions[i].id == SESSION_NY_AM)
         {
            CancelAllPendingOrders();
            g_Plan.state = STATE_SHUTDOWN;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXECUTION ENGINE                                                 |
//+------------------------------------------------------------------+
void ProcessExecutionStateMachine()
{
   if(g_Plan.state == STATE_SHUTDOWN || g_Plan.state == STATE_CLOSED)
      return;
      
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, rates) < 3) return;
   
   double prevClose  = rates[1].close; 
   double prevOpen   = rates[1].open;
   double prevHigh   = rates[1].high;
   double prevLow    = rates[1].low;
   double prev2Close = rates[2].close; 
   
   if(g_Plan.rangeSize > 0.0)
   {
      if(prevHigh > g_Plan.boundaryHigh)
         g_Plan.sweepHighExt = MathMax(g_Plan.sweepHighExt, prevHigh);
      if(prevLow < g_Plan.boundaryLow)
         g_Plan.sweepLowExt = MathMin(g_Plan.sweepLowExt, prevLow);
   }
   
   ulong activeTicket = g_Plan.positionTicket;
   bool hasPosition = HasActivePosition(activeTicket);
   if(hasPosition)
   {
      g_Plan.positionTicket = activeTicket;
      if(g_Plan.state == STATE_PENDING_LIMIT || g_Plan.state == STATE_BREAKOUT_SHIFTED)
         g_Plan.state = STATE_ACTIVE_FILLED;
   }
   
   if(!hasPosition && g_Plan.state == STATE_PENDING_LIMIT)
   {
      double exp = InpModel1TargetR;
      
      if(g_Plan.isLong && prevClose > g_Plan.boundaryHigh && prev2Close <= g_Plan.boundaryHigh)
      {
         CancelAllPendingOrders();
         g_Plan.state           = STATE_BREAKOUT_SHIFTED;
         g_Plan.modelName       = "Model 1: Breakout Retest";
         g_Plan.entryPrice      = NormalizePrice(g_Plan.boundaryHigh);
         g_Plan.slPrice         = NormalizePrice(g_Plan.midline);
         g_Plan.tpPrice         = NormalizePrice(g_Plan.boundaryHigh + (g_Plan.rangeSize * exp));
         
         double adj = g_Plan.entryPrice;
         IsStopsLevelViolated(ORDER_TYPE_BUY_LIMIT, g_Plan.entryPrice, adj);
         double lots = CalculateLotSize(adj, g_Plan.slPrice);
         if(g_Trade.OrderOpen(_Symbol, ORDER_TYPE_BUY_LIMIT, lots, 0.0, adj, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Breakout Shift"))
         {
            g_Plan.pendingTicket = g_Trade.ResultOrder();
            string txt = StringFormat("🔄 [Model 1: Breakout Shift] BUY LIMIT %s\nNew Entry: %.5f\nSL: %.5f\nTP: %.5f", _Symbol, adj, g_Plan.slPrice, g_Plan.tpPrice);
            SendAlert(txt);
         }
      }
      else if(!g_Plan.isLong && prevClose < g_Plan.boundaryLow && prev2Close >= g_Plan.boundaryLow)
      {
         CancelAllPendingOrders();
         g_Plan.state           = STATE_BREAKOUT_SHIFTED;
         g_Plan.modelName       = "Model 1: Breakout Retest";
         g_Plan.entryPrice      = NormalizePrice(g_Plan.boundaryLow);
         g_Plan.slPrice         = NormalizePrice(g_Plan.midline);
         g_Plan.tpPrice         = NormalizePrice(g_Plan.boundaryLow - (g_Plan.rangeSize * exp));
         
         double adj = g_Plan.entryPrice;
         IsStopsLevelViolated(ORDER_TYPE_SELL_LIMIT, g_Plan.entryPrice, adj);
         double lots = CalculateLotSize(adj, g_Plan.slPrice);
         if(g_Trade.OrderOpen(_Symbol, ORDER_TYPE_SELL_LIMIT, lots, 0.0, adj, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Breakout Shift"))
         {
            g_Plan.pendingTicket = g_Trade.ResultOrder();
            string txt = StringFormat("🔄 [Model 1: Breakout Shift] SELL LIMIT %s\nNew Entry: %.5f\nSL: %.5f\nTP: %.5f", _Symbol, adj, g_Plan.slPrice, g_Plan.tpPrice);
            SendAlert(txt);
         }
      }
   }
   
   if(!hasPosition && g_Plan.state == STATE_WAITING_SWEEP_CONFIRMATION)
   {
      static datetime lastModel2BarTime = 0;
      if(rates[0].time == lastModel2BarTime) return;
      
      bool sweptLow  = (g_Plan.sweepLowExt < g_Plan.boundaryLow);
      bool sweptHigh = (g_Plan.sweepHighExt > g_Plan.boundaryHigh);
      
      bool bullRev = sweptLow  && (prevClose > g_Plan.midline) && (prevClose > prevOpen);
      bool bearRev = sweptHigh && (prevClose < g_Plan.midline) && (prevClose < prevOpen);
      
      if(bullRev || bearRev)
      {
         bool newIsLong = bullRev;
         double sweepExt = newIsLong ? g_Plan.sweepLowExt : g_Plan.sweepHighExt;
         
         g_Symbol.RefreshRates();
         double mktEntry = newIsLong ? g_Symbol.Ask() : g_Symbol.Bid();
         
         g_Plan.state      = STATE_SWEEP_REVERSAL;
         g_Plan.modelName  = "Model 2: Sweep Reversal";
         g_Plan.isLong     = newIsLong;
         g_Plan.entryPrice = NormalizePrice(mktEntry);
         g_Plan.slPrice    = NormalizePrice(sweepExt);
         g_Plan.tpPrice    = NormalizePrice(newIsLong ? (mktEntry + (g_Plan.rangeSize * InpModel2TargetR)) : (mktEntry - (g_Plan.rangeSize * InpModel2TargetR)));
         
         double lots = CalculateLotSize(mktEntry, g_Plan.slPrice);
         ENUM_ORDER_TYPE oType = newIsLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         
         if(g_Trade.PositionOpen(_Symbol, oType, lots, 0.0, g_Plan.slPrice, g_Plan.tpPrice, "Model 2: Rev"))
         {
            lastModel2BarTime = rates[0].time;
            ulong pt = g_Trade.ResultDeal();
            if(pt == 0) pt = g_Trade.ResultOrder();
            if(pt == 0) HasActivePosition(pt);
            g_Plan.positionTicket = pt;
            
            string typeStr = newIsLong ? "BUY" : "SELL";
            string txt = StringFormat("🔥 [Model 2: Sweep Reversal] %s %s\nEntry: %.5f\nSL (Wick): %.5f\nTP: %.5f", typeStr, _Symbol, mktEntry, g_Plan.slPrice, g_Plan.tpPrice);
            SendAlert(txt);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_Symbol.Name(_Symbol);
   g_Symbol.RefreshRates();
   g_Trade.SetExpertMagicNumber(InpMagicNumber);
   
   InitSessions();
   g_Plan.state = STATE_CLOSED;
   g_LastBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_LASTBAR_DATE);
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CancelAllPendingOrders();
}

void CheckPendingToActive()
{
   if(g_Plan.state == STATE_PENDING_LIMIT || g_Plan.state == STATE_BREAKOUT_SHIFTED)
   {
      ulong activeTicket = 0;
      if(HasActivePosition(activeTicket))
      {
         g_Plan.positionTicket = activeTicket;
         g_Plan.pendingTicket  = 0;
         g_Plan.state          = STATE_ACTIVE_FILLED;
         
         string txt = StringFormat("✅ [ORDER FILLED] %s Position Opened. Ticket: %d", _Symbol, activeTicket);
         SendAlert(txt);
      }
   }
}

void OnTick()
{
   datetime currentServerTime = TimeCurrent();
   UpdateSessionTracking(currentServerTime);
   
   CheckPendingToActive();
   
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_LASTBAR_DATE);
   if(currentBarTime != g_LastBarTime)
   {
      g_LastBarTime = currentBarTime;
      ProcessExecutionStateMachine();
   }
   
   Comment("ICT Session Range Master\nState: ", EnumToString(g_Plan.state), "\nModel: ", g_Plan.modelName);
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         long reason    = HistoryDealGetInteger(trans.deal, DEAL_REASON);
         ulong posId    = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         
         if(entryType == DEAL_ENTRY_OUT)
         {
            if(posId == g_Plan.positionTicket && posId > 0)
            {
               if(!HasActivePosition(g_Plan.positionTicket))
               {
                  if(reason == DEAL_REASON_SL)
                  {
                     g_Plan.state = STATE_WAITING_SWEEP_CONFIRMATION;
                     g_Plan.positionTicket = 0;
                     SendAlert("⚠️ [SL HIT] " + _Symbol + " Position closed. Transitioning to Sweep Reversal (Model 2).");
                  }
                  else
                  {
                     g_Plan.state = STATE_CLOSED;
                     g_Plan.positionTicket = 0;
                     SendAlert("💰 [TP/MANUAL] " + _Symbol + " Position closed safely. State -> CLOSED.");
                  }
               }
            }
         }
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      if(trans.order == g_Plan.pendingTicket && g_Plan.state == STATE_PENDING_LIMIT)
      {
         if(!HasActiveOrder(g_Plan.pendingTicket))
         {
            ulong tempPos = 0;
            if(!HasActivePosition(tempPos))
            {
               g_Plan.state = STATE_CLOSED;
               g_Plan.pendingTicket = 0;
               SendAlert("🗑️ [ORDER CANCELLED] " + _Symbol + " Pending Limit removed.");
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
