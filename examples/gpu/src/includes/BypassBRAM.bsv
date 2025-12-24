import GetPut::*;
import BRAMCore::*;
import BRAM::*;

// Tries to make a BRAM look like a register
// Reads return the values written on the last cycle
module mkBypassBRAM(BRAM2Port#(a, t)) provisos (Bits#(a, l), Bits#(t, tSz));
  Integer memSize = 2 ** valueOf(l);
  BRAM_DUAL_PORT#(Bit#(l), t) memory       <- mkBRAMCore2(memSize, False);

  Reg#(Bool)                  validA[2]    <- mkCReg(2, False);
  Reg#(Bit#(l))               addressA     <- mkRegU;
  Reg#(Bool)                  validB[2]    <- mkCReg(2, False);
  Reg#(Bit#(l))               addressB     <- mkRegU;
  // data to bypass
  Reg#(Bool)                  bypassValid  <- mkReg(False);
  Reg#(t)                     bypass       <- mkRegU;
  RWire#(BRAMRequest#(a, t))  reqA         <- mkRWire;
  RWire#(BRAMRequest#(a, t))  reqB         <- mkRWire;
  RWire#(void)                clearA       <- mkRWire;
  RWire#(void)                clearB       <- mkRWire;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    let isReqA = isValid(reqA.wget);
    let isReqB = isValid(reqB.wget);
    let isClearA = isValid(clearA.wget);
    let isClearB = isValid(clearB.wget);

    match BRAMRequest {
      write: .wrA, address: .addrA, datain: .dataA
    } = fromMaybe(?, reqA.wget);
    match BRAMRequest {
      write: .wrB, address: .addrB, datain: .dataB
    } = fromMaybe(?, reqB.wget);

    if (!isReqA) addrA = unpack(addressA);
    if (!isReqB) addrB = unpack(addressB);

    let addrEq = pack(addrA) == pack(addrB);
    let writeB = isReqB && wrB;
    // if A and B both write, order B after A
    let writeA = isReqA && wrA && (!writeB || !addrEq);

    // request to memory
    memory.a.put(writeA, pack(addrA), dataA);
    memory.b.put(writeB, pack(addrB), dataB);

    // bypass when there is a write, and the requested addresses are the same
    bypassValid <= ((isReqA && wrA) || (isReqB && wrB)) && addrEq;
    bypass <= isReqB && wrB ? dataB : dataA;

    // update control registers
    addressA <= pack(addrA);
    addressB <= pack(addrB);
    if (isReqA || isClearA)
      validA[1] <= !wrA && !isClearA;
    if (isReqB || isClearB)
      validB[1] <= !wrB && !isClearB;
  endrule

  interface BRAMServer portA;
    interface Put request;
      method Action put(BRAMRequest#(a, t) req) if (!validA[1]);
        reqA.wset(req);
      endmethod
    endinterface
    interface Get response;
      method ActionValue#(t) get if (validA[0]);
        validA[0] <= False;
        return bypassValid ? bypass : memory.a.read;
      endmethod
    endinterface
  endinterface

  interface BRAMServer portB;
    interface Put request;
      method Action put(BRAMRequest#(a, t) req) if (!validB[1]);
        reqB.wset(req);
      endmethod
    endinterface
    interface Get response;
      method ActionValue#(t) get if (validB[0]);
        validB[0] <= False;
        return bypassValid ? bypass : memory.b.read;
      endmethod
    endinterface
  endinterface

  method Action portAClear;
    clearA.wset(?);
  endmethod
  method Action portBClear;
    clearB.wset(?);
  endmethod
endmodule

