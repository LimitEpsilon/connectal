import Vector::*;

typedef Bit#(8) Byte;

typedef 32 AddrSz;
typedef Bit#(AddrSz) Addr;

typedef 32 DataSz;
typedef Bit#(DataSz) Data;

typedef 32 InstSz;
typedef Bit#(InstSz) RawInst;

typedef `THREAD_NUM ThreadNum;
typedef TLog#(ThreadNum) LogThreadNum;
typedef Bit#(LogThreadNum) ThreadId;

typedef `WARP_NUM WarpNum;
typedef TLog#(WarpNum) LogWarpNum;
// LOG_BANK_NUM is the Rocq parameter b: there are 2^b banks, and b must be
// no greater than LogWarpNum.  The remaining warp-id bits index within a bank.
`ifndef LOG_BANK_NUM
`define LOG_BANK_NUM 1
`endif
typedef `LOG_BANK_NUM LogBankNum;
typedef TExp#(LogBankNum) BankNum;
typedef TSub#(LogWarpNum, LogBankNum) LocalWarpNum;
typedef TExp#(LocalWarpNum) WarpsPerBank;
typedef Bit#(LogWarpNum) WarpId;

typedef TMul#(ThreadNum, WarpNum) MaxDivergence;

Bool printDebug = False;
