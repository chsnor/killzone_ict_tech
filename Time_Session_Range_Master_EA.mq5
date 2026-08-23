//+------------------------------------------------------------------+
//|                                Time_Session_Range_Master_EA.mq5  |
//|                    All-in-One ICT Session Range Strategy         |
//|                    Senior Quantitative Developer Edition         |
//+------------------------------------------------------------------+
#property copyright "Senior Quantitative Developer"
#property link      ""
#property version   "6.00"
#property description "Unified EA with Main and FTMO Modes, Auto UTC Offset, and Universal Suffix"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Enums
enum ENUM_TRADING_MODE 
{ 
   MODE_MAIN, // Main Mode (No Limits)
   MODE_FTMO  // FTMO Mode (Strict Rules)
};

enum ENUM_SYSTEM_STATE
{
   STATE_SHUTDOWN,                     
   STATE_PENDING_LIMIT,                
   STATE_BREAKOUT_SHIFTED,             
   STATE_WAITING_SWEEP_CONFIRMATION,   
   STATE_SWEEP_REVERSAL,               
   STATE_ACTIVE_FILLED,                
   STATE_CLOSED                        
};

struct SessionBlock
{
   int      startHour;
   int      startMin;
   int      endHour;
   int      endMin;
   datetime startTime;
   datetime endTime;
   double   highPrice;
   double   lowPrice;
   double   range;
   bool     isActive;
};

struct ExecutionPlan
{
   ENUM_SYSTEM_STATE state;
   string            modelName;
   ulong             pendingTicket;
   ulong             positionTicket;
   double            midline;
   double            rangeSize;
   double            slPrice;
   double            tpPrice;
};

//--- Input Parameters
input string InpModeDiv           = "=== TRADING MODE ===";
input ENUM_TRADING_MODE InpTradingMode = MODE_FTMO; // Select Trading Mode

input string InpRiskDiv           = "=== RISK MANAGEMENT ===";
input double InpRiskPercent       = 1.0;       // Risk Per Trade (%)
input double InpMinLots           = 0.01;      // Minimum Lots
input ulong  InpMagicNumber       = 1337001;   // Magic Number
input bool   InpNoWeekends        = true;      // Halt Trading Over Weekends

input string InpTargetDiv         = "=== TARGET/RR SETTINGS ===";
input double InpModel1TargetR     = 1.0;       // Model 1: Take Profit (R)
input double InpModel2TargetR     = 2.0;       // Model 2: Take Profit (R)

input string InpFtmoDiv           = "=== FTMO SAFETY LIMITS ===";
input double InpDailyMaxLossPercent = 4.0;     // Daily Max Loss Hard Stop (%)
input int    InpFridayCloseHour   = 23;        // Friday Force Close (Hour)
input int    InpFridayCloseMin    = 45;        // Friday Force Close (Minute)
input int    InpMaxSpreadPoints   = 30;        // Max Spread (Points)

input string InpAlertDiv          = "=== ALERT SETTINGS ===";
input bool   InpEnableTelegram    = false;     // Enable Telegram Alerts
input string InpTelegramToken     = "";        // Telegram Bot Token
input string InpTelegramChatID    = "";        // Telegram Chat ID
input bool   InpEnableLineNotify  = false;     // Enable LINE Notify
input string InpLineToken         = "";        // LINE Notify Token

//--- Global Objects
CTrade         g_Trade;
CSymbolInfo    g_Symbol;
SessionBlock   g_Sessions[4];
ExecutionPlan  g_Plan;

int            g_LastDay = -1;
datetime       g_LastBarTime = 0;
int            g_BrokerOffsetHours = 0;

// Dashboard & Stats
double         g_DailyProfit = 0.0;
int            g_DailyTrades = 0;
int            g_DailyWins   = 0;
int            g_DailyLosses = 0;
double         g_TotalProfit = 0.0;
int            g_TotalTrades = 0;
int            g_TotalWins   = 0;
int            g_TotalLosses = 0;

// FTMO Globals
double         g_StartOfDayEquity = 0.0;
bool           g_HardStopActive   = false;

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                |
//+------------------------------------------------------------------+
string GetCleanSymbol()
{
   return _Symbol; // Universal execution handles suffixes natively via _Symbol
}

int CalculateBrokerOffset()
{
   datetime symTime = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if (symTime == 0) symTime = TimeTradeServer();
   datetime gmtTime = TimeGMT();
   int offset = (int)MathRound((double)(symTime - gmtTime) / 3600.0);
   return offset;
}

void InitSessions()
{
   g_BrokerOffsetHours = CalculateBrokerOffset();
   Print("Auto-Detected Broker UTC Offset: +", g_BrokerOffsetHours);
   
   // Asian (19:00 - 23:00 EST -> UTC 00:00 - 04:00)
   g_Sessions[0].startHour = (0 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[0].startMin = 0;
   g_Sessions[0].endHour = (4 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[0].endMin = 0;
   
   // London (01:00 - 04:00 EST -> UTC 06:00 - 09:00)
   g_Sessions[1].startHour = (6 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[1].startMin = 0;
   g_Sessions[1].endHour = (9 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[1].endMin = 0;
   
   // NY AM (07:30 - 10:00 EST -> UTC 12:30 - 15:00)
   g_Sessions[2].startHour = (12 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[2].startMin = 30;
   g_Sessions[2].endHour = (15 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[2].endMin = 0;
   
   // NY PM (12:30 - 15:00 EST -> UTC 17:30 - 20:00)
   g_Sessions[3].startHour = (17 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[3].startMin = 30;
   g_Sessions[3].endHour = (20 + g_BrokerOffsetHours + 24) % 24;
   g_Sessions[3].endMin = 0;
}

void SendAlert(string msg)
{
   Print(msg);
   
   string encodedMsg = msg;
   StringReplace(encodedMsg, " ", "%20");
   StringReplace(encodedMsg, "\n", "%0A");

   char post[], result[];
   string headers;

   if(InpEnableTelegram && InpTelegramToken != "" && InpTelegramChatID != "")
   {
      string url = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage?chat_id=" + InpTelegramChatID + "&text=" + encodedMsg;
      WebRequest("GET", url, "", 5000, post, result, headers);
   }

   if(InpEnableLineNotify && InpLineToken != "")
   {
      string url = "https://notify-api.line.me/api/notify";
      headers = "Authorization: Bearer " + InpLineToken + "\r\nContent-Type: application/x-www-form-urlencoded\r\n";
      string dataStr = "message=" + encodedMsg;
      StringToCharArray(dataStr, post);
      ArrayResize(post, ArraySize(post)-1);
      WebRequest("POST", url, headers, 5000, post, result, headers);
   }
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ot = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         g_Trade.OrderDelete(ot);
      }
   }
   g_Plan.pendingTicket = 0;
}

void FTMOCloseAll(string reason)
{
   SendAlert("🚨 [FTMO FORCE CLOSE] " + reason + " - Closing all active positions and orders!");
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         g_Trade.PositionClose(pt);
      }
   }
   
   CancelAllPendingOrders();
   g_Plan.state = STATE_SHUTDOWN;
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

bool IsNewBar()
{
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_LASTBAR_DATE);
   if(currentBarTime != g_LastBarTime)
   {
      g_LastBarTime = currentBarTime;
      return true;
   }
   return false;
}

bool HasActivePosition(ulong &ticketOut)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ticketOut = pt;
         return true;
      }
   }
   return false;
}

bool HasActivePosition()
{
   ulong dummy;
   return HasActivePosition(dummy);
}

bool HasActiveOrder(ulong ticket)
{
   return OrderSelect(ticket);
}

double GetPositionSize(double riskPercent, double slDistance)
{
   if(slDistance <= 0) return InpMinLots;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickSize == 0 || tickValue == 0) return InpMinLots;
   
   double pointValue = tickValue / (tickSize / _Point); 
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (riskPercent / 100.0);
   double slPoints = slDistance / _Point;
   double moneyPerLot = slPoints * pointValue;
   
   if(moneyPerLot <= 0) return InpMinLots;
   
   double lots = riskMoney / moneyPerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;
   
   if(lots < InpMinLots) lots = InpMinLots;
   double maxLots = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lots > maxLots) lots = maxLots;
   
   return lots;
}

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_Symbol.Name(_Symbol);
   g_Symbol.RefreshRates();
   g_Trade.SetExpertMagicNumber(InpMagicNumber);
   
   InitSessions();
   g_Plan.state = STATE_CLOSED;
   
   g_LastBarTime = iTime(_Symbol, PERIOD_M15, 0);
   
   string modeStr = (InpTradingMode == MODE_FTMO) ? "FTMO (Strict Safety)" : "MAIN (Unrestricted)";
   PrintFormat("🚀 [INIT SUCCESS] EA v6.0 on %s | Mode: %s | Risk: %.2f%% | Magic: %d", 
               _Symbol, modeStr, InpRiskPercent, InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   Print("🛑 [DEINIT] EA Stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| STATE MACHINE & LOGIC                                            |
//+------------------------------------------------------------------+
void UpdateSessionTracking(datetime currentServerTime)
{
   MqlDateTime dt;
   TimeToStruct(currentServerTime, dt);
   
   if(dt.day != g_LastDay)
   {
      g_LastDay = dt.day;
      g_DailyProfit = 0.0;
      g_DailyTrades = 0;
      g_DailyWins = 0;
      g_DailyLosses = 0;
      
      g_StartOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_HardStopActive = false;
      
      SendAlert(StringFormat("📅 [NEW DAY] Stats reset. Date: %d-%02d-%02d | Mode: %s", 
                dt.year, dt.mon, dt.day, (InpTradingMode == MODE_FTMO) ? "FTMO" : "MAIN"));
                
      if(g_Plan.state == STATE_CLOSED)
      {
         g_Plan.state = STATE_SHUTDOWN;
      }
   }
   
   double currentClose = iClose(_Symbol, PERIOD_M15, 0);
   int currentMinOfDay = dt.hour * 60 + dt.min;
   
   for(int i = 0; i < 4; i++)
   {
      int startMinOfDay = g_Sessions[i].startHour * 60 + g_Sessions[i].startMin;
      int endMinOfDay   = g_Sessions[i].endHour * 60 + g_Sessions[i].endMin;
      
      bool inSession = false;
      if(startMinOfDay < endMinOfDay)
      {
         inSession = (currentMinOfDay >= startMinOfDay && currentMinOfDay < endMinOfDay);
      }
      else
      {
         inSession = (currentMinOfDay >= startMinOfDay || currentMinOfDay < endMinOfDay);
      }
      
      if(inSession)
      {
         if(!g_Sessions[i].isActive)
         {
            g_Sessions[i].isActive = true;
            g_Sessions[i].startTime = currentServerTime;
            g_Sessions[i].highPrice = currentClose;
            g_Sessions[i].lowPrice  = currentClose;
         }
         else
         {
            double high = iHigh(_Symbol, PERIOD_M15, 0);
            double low  = iLow(_Symbol, PERIOD_M15, 0);
            if(high > g_Sessions[i].highPrice) g_Sessions[i].highPrice = high;
            if(low < g_Sessions[i].lowPrice)   g_Sessions[i].lowPrice = low;
         }
         g_Sessions[i].range = g_Sessions[i].highPrice - g_Sessions[i].lowPrice;
         g_Sessions[i].endTime = currentServerTime;
      }
      else
      {
         if(g_Sessions[i].isActive)
         {
            g_Sessions[i].isActive = false;
            OnSessionClose(i);
         }
      }
   }
}

void CheckPendingToActive()
{
   ulong activeTicket = 0;
   if(HasActivePosition(activeTicket))
   {
      g_Plan.positionTicket = activeTicket;
      if(g_Plan.state == STATE_PENDING_LIMIT || g_Plan.state == STATE_BREAKOUT_SHIFTED)
      {
         g_Plan.state = STATE_ACTIVE_FILLED;
         SendAlert(StringFormat("✅ [ORDER FILLED] %s Position Opened. Ticket: %d", _Symbol, activeTicket));
      }
   }
}

void OnSessionClose(int sessionIndex)
{
   if(InpTradingMode == MODE_FTMO && g_HardStopActive) return;
   
   if(sessionIndex == 2)
   {
      g_Plan.state = STATE_SHUTDOWN;
      CancelAllPendingOrders();
      SendAlert("🛑 [DAILY SHUTDOWN] NY AM Session Closed. Trading halted until NY PM.");
      return;
   }
   
   if(g_Plan.state == STATE_SHUTDOWN && sessionIndex != 3) return;
   
   if(HasActivePosition()) return;
   
   CancelAllPendingOrders();
   InitPendingOrder(sessionIndex);
}

void InitPendingOrder(int sessionIndex)
{
   SessionBlock refSess = g_Sessions[sessionIndex];
   double midline = refSess.lowPrice + (refSess.range * 0.5);
   
   g_Plan.midline   = midline;
   g_Plan.rangeSize = refSess.range;
   
   double lastClose = iClose(_Symbol, PERIOD_M15, 1);
   bool isLong = (lastClose > midline);
   
   ENUM_ORDER_TYPE oType = isLong ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   double entryPrice = midline;
   
   double slDist = refSess.range * 0.5;
   double lots = GetPositionSize(InpRiskPercent, slDist);
   
   if(isLong)
   {
      g_Plan.slPrice = NormalizePrice(refSess.lowPrice);
      g_Plan.tpPrice = NormalizePrice(entryPrice + (refSess.range * InpModel1TargetR));
   }
   else
   {
      g_Plan.slPrice = NormalizePrice(refSess.highPrice);
      g_Plan.tpPrice = NormalizePrice(entryPrice - (refSess.range * InpModel1TargetR));
   }
   
   double adjEntry = NormalizePrice(entryPrice);
   
   if(InpTradingMode == MODE_FTMO && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) 
   {
      SendAlert("⚠️ [FTMO] Spread too high (" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + "), skipping Model 1 pending.");
      return;
   }
   
   if(g_Trade.OrderOpen(_Symbol, oType, lots, 0.0, adjEntry, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Target"))
   {
      g_Plan.state         = STATE_PENDING_LIMIT;
      g_Plan.modelName     = "Model 1: Continue Range";
      g_Plan.pendingTicket = g_Trade.ResultOrder();
      
      string txt = StringFormat("⏳ [PENDING LIMIT] %s %s at %.5f | SL: %.5f | TP: %.5f",
                                _Symbol, (isLong ? "BUY" : "SELL"), adjEntry, g_Plan.slPrice, g_Plan.tpPrice);
      SendAlert(txt);
   }
}

void ProcessExecutionStateMachine()
{
   if(InpTradingMode == MODE_FTMO && g_HardStopActive) return;
   
   double lastClose = iClose(_Symbol, PERIOD_M15, 1);
   
   if(g_Plan.state == STATE_PENDING_LIMIT && g_Plan.pendingTicket > 0)
   {
      bool isLong = (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT);
      bool breakout = isLong ? (lastClose < g_Plan.slPrice) : (lastClose > g_Plan.slPrice);
      
      if(breakout)
      {
         CancelAllPendingOrders();
         
         double newEntry = isLong ? g_Plan.slPrice : g_Plan.slPrice;
         double newSl    = g_Plan.midline;
         double newTp    = isLong ? (newEntry - (g_Plan.rangeSize * InpModel1TargetR)) : (newEntry + (g_Plan.rangeSize * InpModel1TargetR));
         
         g_Plan.slPrice = NormalizePrice(newSl);
         g_Plan.tpPrice = NormalizePrice(newTp);
         
         double slDist = MathAbs(newEntry - newSl);
         double lots = GetPositionSize(InpRiskPercent, slDist);
         double adj = NormalizePrice(newEntry);
         
         if(InpTradingMode == MODE_FTMO && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) return;
         
         if(isLong)
         {
            if(g_Trade.OrderOpen(_Symbol, ORDER_TYPE_SELL_LIMIT, lots, 0.0, adj, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Breakout Shift"))
            {
               g_Plan.state = STATE_BREAKOUT_SHIFTED;
               g_Plan.pendingTicket = g_Trade.ResultOrder();
               SendAlert("🔄 [RETEST SHIFT] Breakout detected. Shifted to SELL LIMIT at boundary.");
            }
         }
         else
         {
            if(g_Trade.OrderOpen(_Symbol, ORDER_TYPE_BUY_LIMIT, lots, 0.0, adj, g_Plan.slPrice, g_Plan.tpPrice, ORDER_TIME_GTC, 0, "Model 1: Breakout Shift"))
            {
               g_Plan.state = STATE_BREAKOUT_SHIFTED;
               g_Plan.pendingTicket = g_Trade.ResultOrder();
               SendAlert("🔄 [RETEST SHIFT] Breakout detected. Shifted to BUY LIMIT at boundary.");
            }
         }
      }
   }
   else if(g_Plan.state == STATE_WAITING_SWEEP_CONFIRMATION)
   {
      bool newIsLong = (lastClose > g_Plan.midline);
      double currentHigh = iHigh(_Symbol, PERIOD_M15, 1);
      double currentLow  = iLow(_Symbol, PERIOD_M15, 1);
      
      if((newIsLong && currentLow < g_Plan.midline) || (!newIsLong && currentHigh > g_Plan.midline))
      {
         ENUM_ORDER_TYPE oType = newIsLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         
         g_Plan.slPrice    = NormalizePrice(newIsLong ? currentLow : currentHigh);
         double slDist     = MathAbs(lastClose - g_Plan.slPrice);
         double lots       = GetPositionSize(InpRiskPercent, slDist);
         
         double mktEntry   = SymbolInfoDouble(_Symbol, newIsLong ? SYMBOL_ASK : SYMBOL_BID);
         g_Plan.tpPrice    = NormalizePrice(newIsLong ? (mktEntry + (g_Plan.rangeSize * InpModel2TargetR)) : (mktEntry - (g_Plan.rangeSize * InpModel2TargetR)));
         
         if(InpTradingMode == MODE_FTMO && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) 
         {
            SendAlert("⚠️ [FTMO] Spread too high, skipping Model 2 Sweep.");
            return;
         }
         
         if(g_Trade.PositionOpen(_Symbol, oType, lots, 0.0, g_Plan.slPrice, g_Plan.tpPrice, "Model 2: Rev"))
         {
            g_Plan.state = STATE_SWEEP_REVERSAL;
            SendAlert("⚡ [SWEEP REVERSAL] " + _Symbol + " Position Opened. Model 2 Active.");
         }
      }
   }
}

void RenderDashboard()
{
   string modeTxt = (InpTradingMode == MODE_FTMO) ? "FTMO (Safety ON)" : "MAIN (Unlimited)";
   string db = "=== ICT Range Master v6.0 ===\n";
   db += "Symbol: " + _Symbol + " | Mode: " + modeTxt + "\n";
   db += "Broker Offset: +" + IntegerToString(g_BrokerOffsetHours) + " UTC\n";
   db += "State: " + EnumToString(g_Plan.state) + "\n";
   db += "Model: " + g_Plan.modelName + "\n";
   if(InpTradingMode == MODE_FTMO)
   {
      db += StringFormat("Daily Eq Start: %.2f\n", g_StartOfDayEquity);
      db += "Hard Stop Active: " + (g_HardStopActive ? "YES" : "NO") + "\n";
   }
   db += StringFormat("Daily PnL: %.2f | Trades: %d\n", g_DailyProfit, g_DailyTrades);
   db += StringFormat("Total PnL: %.2f | Trades: %d", g_TotalProfit, g_TotalTrades);
   Comment(db);
}

void OnTick()
{
   datetime currentServerTime = TimeCurrent();
   UpdateSessionTracking(currentServerTime);
   
   if(InpTradingMode == MODE_FTMO)
   {
      MqlDateTime dt;
      TimeToStruct(currentServerTime, dt);
      
      // 1. Friday Force Close
      if(dt.day_of_week == 5 && (dt.hour > InpFridayCloseHour || (dt.hour == InpFridayCloseHour && dt.min >= InpFridayCloseMin)))
      {
         if(g_Plan.state != STATE_SHUTDOWN)
         {
            FTMOCloseAll("Friday Trading Hours Over");
         }
         return;
      }
      
      // 2. Daily Max Loss Hard Stop
      if(!g_HardStopActive && g_StartOfDayEquity > 0)
      {
         double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         double maxLossEquity = g_StartOfDayEquity * (1.0 - (InpDailyMaxLossPercent / 100.0));
         if(currentEquity <= maxLossEquity)
         {
            g_HardStopActive = true;
            FTMOCloseAll(StringFormat("Daily Max Loss Reached! Equity dropped to %.2f (Limit: %.2f)", currentEquity, maxLossEquity));
            return;
         }
      }
   }
   
   if((InpTradingMode == MODE_FTMO && g_HardStopActive) || g_Plan.state == STATE_SHUTDOWN) return;
   
   CheckPendingToActive();
   
   if(IsNewBar())
   {
      ProcessExecutionStateMachine();
   }
   
   RenderDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         if(dealMagic == InpMagicNumber && HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
         {
            ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            if(dealEntry == DEAL_ENTRY_OUT)
            {
               double rawProfit  = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
               double swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
               double netProfit  = rawProfit + commission + swap;
               
               g_DailyProfit += netProfit;
               g_TotalProfit += netProfit;
               
               if(HasActivePosition()) return;
               
               CancelAllPendingOrders();
               
               g_Plan.pendingTicket   = 0;
               g_Plan.positionTicket  = 0;
               g_DailyTrades++;
               g_TotalTrades++;
               
               if(netProfit > 0.0)
               {
                  g_DailyWins++;
                  g_TotalWins++;
                  g_Plan.state = STATE_CLOSED;
                  SendAlert(StringFormat("🎉 [FULL TP] Deal: %d | Net: %.2f", dealTicket, netProfit));
               }
               else
               {
                  g_DailyLosses++;
                  g_TotalLosses++;
                  SendAlert(StringFormat("🛑 [SL HIT] Deal: %d | Net: %.2f", dealTicket, netProfit));
                  
                  if(g_Plan.state != STATE_SWEEP_REVERSAL)
                  {
                     g_Plan.state     = STATE_WAITING_SWEEP_CONFIRMATION;
                     g_Plan.modelName = "Model 2: Sweep & Turn Around";
                  }
                  else
                  {
                     g_Plan.state = STATE_CLOSED;
                  }
               }
            }
         }
      }
   }
}
