import GetPut::*;
import Types::*;

typedef 16 NumTokens;
typedef Bit#(TLog#(NumTokens)) Token;

typedef 16 LoadBufferSz;
typedef Bit#(TLog#(LoadBufferSz)) LoadBufferIndex;

typedef struct {
  Addr addr;
  Data data;
} MemInitLoad deriving(Eq, Bits, FShow);

typedef union tagged {
  MemInitLoad InitLoad;
  void InitDone;
} MemInit deriving(Eq, Bits, FShow);

interface MemInitIfc;
  interface Put#(MemInit) request;
  method Bool done();
endinterface

typedef 25 MemHeight; // h
typedef 512 PhysDataSz; // w8 = 8 * 2ʷ
typedef TLog#(TDiv#(PhysDataSz, 8)) MemWidth; // w
typedef TAdd#(MemHeight, MemWidth) PhysAddrSz;

