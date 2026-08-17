/*

Copyright (C) 2012 Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Types::*;
import ProcTypes::*;
import ConfigReg::*;
import FIFOF::*;
import Vector::*;

typedef struct {
  CSR csr;
  Bool write;
  Data data;
  Bit#(LogWarpNum) wid;
  Bit#(n) mask;
} CsrReq#(numeric type n) deriving(Bits, Eq, FShow);

typedef struct {
  Vector#(n, Data) datas;
} CsrResp#(numeric type n) deriving(Bits, Eq, FShow);

// shared by all threads that are controlled by a single warp
// especially, the mscratch register is used to place the address to the kernel argument structure
interface CsrFile#(numeric type n);
  method Action start(Data kernel_arg);
  method ActionValue#(Tuple2#(Data, Data)) stop;
  method Action newInst(UInt#(TLog#(TAdd#(1, ThreadNum))) count);
  method Bool started;
  method Action putCsrReq(CsrReq#(n) req);
  method ActionValue#(CsrResp#(n)) getCsrResp;
endinterface

(* synthesize *)
module mkCsrFile(CsrFile#(ThreadNum));
  Reg#(Bool) startReg <- mkConfigReg(False);
  Reg#(CSR) pendingAddr <- mkRegU;
  Reg#(Maybe#(Data)) pending <- mkReg(tagged Invalid);
  FIFOF#(Vector#(ThreadNum, Data)) resps <- mkLFIFOF;

  // CSR
  Reg#(Data) numInsts <- mkReg(0); // csrInstret -- read only
  Reg#(Data) cycles <- mkReg(0); // csrCycle -- read only
  Reg#(Data) scratch <- mkReg(0); // csrScratch -- read/write
  Bit#(TLog#(TAdd#(WarpNum, 1))) nw = fromInteger(valueOf(WarpNum));
  Bit#(TLog#(TAdd#(ThreadNum, 1))) nt = fromInteger(valueOf(ThreadNum));

  Bool isPending = isValid(pending);

  (* fire_when_enabled *)
  rule count (startReg);
    if (printDebug)
      $display("\nCycle %d ----------------------------------------------------", cycles);
    cycles <= cycles + 1;
    // if (cycles > 10000) $finish;
  endrule

  // MMIO, sequentialized as RMW
  rule wr (isPending);
    let data = fromMaybe(?, pending);
    case (pendingAddr)
      CSRmscratch: scratch <= data;
    endcase
    pending <= tagged Invalid;
  endrule

  method Action start(Data kernel_arg) if (!startReg && !isPending);
    startReg <= True;
    cycles <= 0;
    numInsts <= 0;
    scratch <= kernel_arg;
  endmethod

  method ActionValue#(Tuple2#(Data, Data)) stop if (startReg);
    startReg <= False;
    return tuple2(cycles, numInsts);
  endmethod

  method Action newInst(UInt#(TLog#(TAdd#(1, ThreadNum))) count) if (startReg);
    numInsts <= numInsts + pack(extend(count));
  endmethod

  method Bool started;
    return startReg;
  endmethod

  method Action putCsrReq(CsrReq#(ThreadNum) req) if (startReg && !isPending);
    match CsrReq {write: .wr, csr: .csr, data: .data, wid: .wid, mask: .mask} = req;
    pendingAddr <= csr;
    if (wr) begin
      pending <= tagged Valid data;
      resps.enq(unpack(0));
    end else begin
      Vector#(ThreadNum, Data) rd;
      for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1) begin
        Bit#(TLog#(ThreadNum)) tid = fromInteger(i);
        rd[i] =
          case(csr)
            CSRmcycle: cycles;
            CSRminstret: numInsts;
            CSRmhartid: zeroExtend({wid, tid});
            CSRmscratch: scratch;
            CSRnc: 1;
            CSRnw: zeroExtend(nw);
            CSRnt: zeroExtend(nt);
            CSRcid: 0;
            CSRwid: zeroExtend(wid);
            CSRtid: zeroExtend(tid);
            CSRtmask: zeroExtend(mask);
            default: 0;
          endcase;
      end
      resps.enq(rd);
    end
  endmethod

  method ActionValue#(CsrResp#(ThreadNum)) getCsrResp if (startReg);
    let datas = resps.first;

    resps.deq;
    return CsrResp {datas: datas};
  endmethod
endmodule
