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
typedef Bit#(LogWarpNum) WarpId;

typedef TMul#(ThreadNum, WarpNum) MaxDivergence;

Bool printDebug = False;

