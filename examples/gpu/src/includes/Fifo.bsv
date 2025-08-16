import Vector::*;
import FIFOF::*;
import GetPut::*;
import BRAMCore::*;
import ConfigReg::*;

//////////////////
// Fifo interface

interface Fifo#(numeric type n, type t);
  method Bool notFull;
  method Action enq(t x);
  method Bool notEmpty;
  method Action deq;
  method t first;
  method Action clear;
endinterface

/////////////////
// Pipeline FIFO

// Intended schedule:
//      {notEmpty, first, deq} < {notFull, enq} < clear
module mkPipelineFifo#(Bool guardEnq, Bool guardDeq) (Fifo#(n, t)) provisos (Bits#(t,tSz));
  // n is size of fifo
  // t is data type of fifo
  Vector#(n, Reg#(t))     data      <- replicateM(mkRegU);
  RWire#(void)            enqReq    <- mkRWire;
  RWire#(void)            deqReq    <- mkRWire;
  RWire#(void)            clearReq  <- mkRWire;
  Reg#(Bit#(TLog#(n)))    enqP      <- mkReg(0);
  Reg#(Bit#(TLog#(n)))    deqP      <- mkReg(0);
  Reg#(Bool)              empty     <- mkReg(True);
  Reg#(Bool)              full      <- mkReg(False);
  Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

  let nextEnqP = (enqP == max_index) ? 0 : enqP + 1;
  let nextDeqP = (deqP == max_index) ? 0 : deqP + 1;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    if (isValid(clearReq.wget)) begin
      enqP <= 0;
      deqP <= 0;
      empty <= True;
      full <= False;
    end else if (isValid(enqReq.wget)) begin
      enqP <= nextEnqP;
      if (isValid(deqReq.wget))
        deqP <= nextDeqP;
      else begin
        empty <= False;
        full <= nextEnqP == deqP;
      end
    end else if (isValid(deqReq.wget)) begin
      deqP <= nextDeqP;
      empty <= nextDeqP == enqP;
      full <= False;
    end
  endrule

  method Bool notFull = isValid(deqReq.wget) || !full;

  method Action enq(t x) if (!guardEnq || isValid(deqReq.wget) || !full);
    data[enqP] <= x;
    enqReq.wset(?);
  endmethod

  method Bool notEmpty = !empty;

  method Action deq if (!guardDeq || !empty);
    deqReq.wset(?);
  endmethod

  method t first if (!guardDeq || !empty);
    return data[deqP];
  endmethod

  method Action clear;
    clearReq.wset(?);
  endmethod
endmodule

//////////////
// Bypass FIFO

// Intended schedule:
//      {notFull, enq} < {notEmpty, first, deq} < clear
module mkBypassFifo#(Bool guardEnq, Bool guardDeq) (Fifo#(n, t)) provisos (Bits#(t, tSz));
  // n is size of fifo
  // t is data type of fifo
  Vector#(n, Reg#(t))     data      <- replicateM(mkRegU);
  RWire#(t)               enqReq    <- mkRWire;
  RWire#(void)            deqReq    <- mkRWire;
  RWire#(void)            clearReq  <- mkRWire;
  Reg#(Bit#(TLog#(n)))    enqP      <- mkReg(0);
  Reg#(Bit#(TLog#(n)))    deqP      <- mkReg(0);
  Reg#(Bool)              empty     <- mkReg(True);
  Reg#(Bool)              full      <- mkReg(False);
  Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

  let nextEnqP = (enqP == max_index) ? 0 : enqP + 1;
  let nextDeqP = (deqP == max_index) ? 0 : deqP + 1;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    if (isValid(clearReq.wget)) begin
      enqP <= 0;
      deqP <= 0;
      empty <= True;
      full <= False;
    end else if (enqReq.wget matches tagged Valid .x) begin
      enqP <= nextEnqP;
      data[enqP] <= x;
      if (isValid(deqReq.wget))
        deqP <= nextDeqP;
      else begin
        empty <= False;
        full <= nextEnqP == deqP;
      end
    end else if (isValid(deqReq.wget)) begin
      deqP <= nextDeqP;
      empty <= nextDeqP == enqP;
      full <= False;
    end
  endrule

  method Bool notFull = !full;

  method Action enq(t x) if (!guardEnq || !full);
    enqReq.wset(x);
  endmethod

  method Bool notEmpty = isValid(enqReq.wget) || !empty;

  method Action deq if (!guardDeq || isValid(enqReq.wget) || !empty);
    deqReq.wset(?);
  endmethod

  method t first if (!guardDeq || isValid(enqReq.wget) || !empty);
    return empty ? fromMaybe(?, enqReq.wget) : data[deqP];
  endmethod

  method Action clear;
    clearReq.wset(?);
  endmethod
endmodule

//////////////////////
// Conflict-free fifo

// Intended schedule:
//      {notFull, enq} CF {notEmpty, first, deq}
//      {notFull, enq, notEmpty, first, deq} < clear
module mkCFFifo#(Bool guardEnq, Bool guardDeq) (Fifo#(n, t)) provisos (Bits#(t, tSz));
  // n is size of fifo
  // t is data type of fifo
  Vector#(n, Reg#(t))     data      <- replicateM(mkRegU);
  RWire#(t)               enqReq    <- mkRWire;
  RWire#(void)            deqReq    <- mkRWire;
  RWire#(void)            clearReq  <- mkRWire;
  Reg#(Bit#(TLog#(n)))    enqP      <- mkReg(0);
  Reg#(Bit#(TLog#(n)))    deqP      <- mkReg(0);
  Reg#(Bool)              empty     <- mkReg(True);
  Reg#(Bool)              full      <- mkReg(False);
  Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

  let nextEnqP = (enqP == max_index) ? 0 : enqP + 1;
  let nextDeqP = (deqP == max_index) ? 0 : deqP + 1;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    if (isValid(clearReq.wget)) begin
      enqP <= 0;
      deqP <= 0;
      empty <= True;
      full <= False;
    end else if (enqReq.wget matches tagged Valid .x) begin
      data[enqP] <= x;
      enqP <= nextEnqP;
      if (isValid(deqReq.wget))
        deqP <= nextDeqP;
      else begin
        empty <= False;
        full <= nextEnqP == deqP;
      end
    end else if (isValid(deqReq.wget)) begin
      deqP <= nextDeqP;
      empty <= nextDeqP == enqP;
      full <= False;
    end
  endrule

  method Bool notFull = !full;

  method Action enq(t x) if (!guardEnq || !full);
    enqReq.wset(x);
  endmethod

  method Bool notEmpty = !empty;

  method Action deq if (!guardDeq || !empty);
    deqReq.wset(?);
  endmethod

  method t first if (!guardDeq || !empty);
    return data[deqP];
  endmethod

  method Action clear;
    clearReq.wset(?);
  endmethod
endmodule

// from src/Libraries/Base3-Misc/BRAMFIFO.bsv
module mkBRAMFifo#(Bool guardEnq, Bool guardDeq) (Fifo#(n, t))
  provisos (Bits#(t, tSz), Log#(n, l), Add#(1, l, d));

  Integer memSize = 2 ** valueOf(l);
  BRAM_DUAL_PORT#(Bit#(l), t)          memory    <- mkBRAMCore2(memSize, False);

  Reg#(Bit#(d))                        rWrPtr    <- mkConfigReg(0);
  PulseWire                            pwDequeue <- mkPulseWire;
  PulseWire                            pwEnqueue <- mkPulseWire;
  PulseWire                            pwClear   <- mkPulseWire;
  Wire#(t)                             wDataIn   <- mkDWire(?);
  Reg#(Bit#(d))                        rRdPtr    <- mkConfigReg(0);
  Wire#(t)                             wDataOut  <- mkDWire(?);

  Reg#(Maybe#(Tuple2#(Bit#(d), t)))    rCache    <- mkReg(tagged Invalid);

  Bool empty = rRdPtr == rWrPtr;
  Bool full  = rRdPtr + fromInteger(valueOf(n)) == rWrPtr;

  (* fire_when_enabled, no_implicit_conditions, aggressive_implicit_conditions *)
  rule portA;
    if (pwClear) begin
      rWrPtr <= 0;
    end else if (pwEnqueue) begin
      memory.a.put(True, truncate(rWrPtr), wDataIn);
      rCache <= tagged Valid tuple2(rWrPtr, wDataIn);  // cache last write
      rWrPtr <= rWrPtr + 1;
    end else begin
      memory.a.put(False, truncate(rWrPtr), ?);
    end
  endrule

  (* fire_when_enabled, no_implicit_conditions, aggressive_implicit_conditions *)
  rule portB;
    if (pwClear) begin
      rRdPtr <= 0;
    end else if (pwDequeue) begin
      memory.b.put(False, truncate(rRdPtr+1), ?);
      rRdPtr <= rRdPtr + 1;
    end else begin
      memory.b.put(False, truncate(rRdPtr), ?);
    end
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule portB_read_data;
    // if the read data is for the last address written, bypass the BRAM
    // and use the data stored in the cache.
    if (rCache matches tagged Valid {.addr, .data} &&& (addr == rRdPtr))
      wDataOut <= data;
    else
      wDataOut <= memory.b.read;
  endrule

  method Action enq(t sendData) if (!guardEnq || !full);
    pwEnqueue.send;
    wDataIn <= sendData;
  endmethod

  method Action deq if (!guardDeq || !empty);
    pwDequeue.send;
  endmethod

  method t first if (!guardDeq || !empty);
    return wDataOut;
  endmethod

  method Bool notFull  = !full;
  method Bool notEmpty = !empty;

  method Action clear;
    pwClear.send();
  endmethod
endmodule

module mkLatencyFifo#(Bool guardEnq, Bool guardDeq) (Fifo#(n, t)) provisos (Bits#(t, tSz), Add#(subn, 2, n));
  FIFOF#(t) frontStage <- mkGFIFOF(!guardEnq, False);
  Vector#(subn, FIFOF#(t)) middle <- replicateM(mkLFIFOF);
  FIFOF#(t) endStage <- mkGFIFOF(False, !guardDeq);

  for (Integer i = 1; i < valueOf(subn); i = i + 1) begin
    (* fire_when_enabled *)
    rule shift_middle;
      middle[i].enq(middle[i-1].first);
      middle[i-1].deq;
    endrule
  end

  if (valueOf(subn) != 0) begin
    (* fire_when_enabled *)
    rule shift_front;
      middle[0].enq(frontStage.first);
      frontStage.deq;
    endrule

    (* fire_when_enabled *)
    rule shift_end;
      endStage.enq(middle[valueOf(subn)-1].first);
      middle[valueOf(subn)-1].deq;
    endrule
  end else begin
    (* fire_when_enabled *)
    rule shift;
      endStage.enq(frontStage.first);
      frontStage.deq;
    endrule
  end

  method Action enq(t x) = frontStage.enq(x);
  method Action deq = endStage.deq;
  method t first = endStage.first;
  method Bool notFull = frontStage.notFull;
  method Bool notEmpty = endStage.notEmpty;
  method Action clear;
    frontStage.clear;
    for (Integer i = 0; i < valueOf(subn); i = i + 1)
      middle[i].clear;
    endStage.clear;
  endmethod
endmodule

////////////////////////////////
// instances of ToGet and ToPut

instance ToGet#(Fifo#(n, t), t) provisos (Bits#(t, tsz));
  function Get#(t) toGet(Fifo#(n, t) fifo);
    return (
      interface Get#(t);
        method ActionValue#(t) get();
          let x = fifo.first;
          fifo.deq;
          return x;
        endmethod
      endinterface);
  endfunction
endinstance

instance ToPut#(Fifo#(n, t), t) provisos (Bits#(t, tsz));
  function Put#(t) toPut(Fifo#(n, t) fifo);
    return (
      interface Put#(t);
        method Action put(t x);
          fifo.enq(x);
        endmethod
      endinterface);
  endfunction
endinstance
