/*

Copyright (C) 2012 Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Types::*;
import ProcTypes::*;
import Vector::*;
import FIFOF::*;
import SpecialFIFOs::*;
import Fifo::*;
import BRAM::*;
import Count::*;

// Each physical bank holds 64 architectural registers (GPR + FPR), or
// 32 FPRs, for every local warp assigned to that bank.
typedef TAdd#(6, LocalWarpNum) LaneRIndxSz;
typedef TAdd#(5, LocalWarpNum) FPRIndxSz;
typedef Bit#(LaneRIndxSz) LaneRIndx;
typedef Bit#(FPRIndxSz) FPRIndx;
typedef TExp#(LaneRIndxSz) RegPerLane;
typedef TExp#(FPRIndxSz) FPRPerLane;

typedef struct {
  Bool    conv;
  RIndx   rs1;
  RIndx   rs2;
  RIndx   rs3;
} RFRdReq deriving (Bits, Eq, FShow);

typedef struct {
  Bool    conv;
  RIndx   rd;
  Bit#(n) mask;
  Vector#(n, Data) datas;
} RFWrReq#(numeric type n) deriving (Bits, Eq, FShow);

typedef struct {
  Bool    write;
  Bool    conv;
  RIndx   rs1;
  RIndx   rs2;
  RIndx   rs3;
  RIndx   rd;
  Bit#(n) mask;
  Vector#(n, Data) datas;
} RFReq#(numeric type n) deriving (Bits, Eq, FShow);

function RFReq#(ThreadNum) fromRdReq(RFRdReq req);
  match RFRdReq {conv: .conv, rs1: .rs1, rs2: .rs2, rs3: .rs3} = req;
  return RFReq {
    write: False, conv: conv, rs1: rs1, rs2: rs2, rs3: rs3, rd: ?, mask: ?, datas: ?
  };
endfunction

function RFReq#(n) fromWrReq(RFWrReq#(n) req);
  match RFWrReq {conv: .conv, rd: .rd, mask: .mask, datas: .datas} = req;
  return RFReq {
    write: True, conv: conv, rs1: ?, rs2: ?, rs3: ?, rd: rd, mask: mask, datas: datas
  };
endfunction

typedef struct {
  Vector#(n, Data) rv1;
  Vector#(n, Data) rv2;
  Vector#(n, Data) rv3;
} RFResp#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorRFile#(numeric type n);
  method Action ask(RFReq#(n) req, Bit#(LocalWarpNum) wid);
  method Bool notFull;
  method ActionValue#(RFResp#(n)) ans;
endinterface

(* synthesize *)
module mkRFileBRAM(BRAM2Port#(LaneRIndx, Data));
  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = valueOf(RegPerLane);
  let ram <- mkBRAM2Server(cfg);
  return ram;
endmodule

(* synthesize *)
module mkFPRBRAM(BRAM1Port#(FPRIndx, Data));
  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = valueOf(FPRPerLane);
  let ram <- mkBRAM1Server(cfg);
  return ram;
endmodule

module mkVecRFile(VectorRFile#(n));
  Vector#(n, BRAM2Port#(LaneRIndx, Data)) rfiles <- replicateM(mkRFileBRAM);
  Vector#(n, BRAM1Port#(FPRIndx, Data)) fpr <- replicateM(mkFPRBRAM);
  // A non-loopy request FIFO cuts req_BRAM dequeue readiness out of ask.
  FIFOF#(Tuple2#(RFReq#(n), Bit#(LocalWarpNum))) reqs <- mkFIFOF;
  FIFOF#(Bool) respAisZero <- mkUGFIFOF;
  FIFOF#(Vector#(n, Data)) respA <- mkFIFOF;
  FIFOF#(Bool) respBisZero <- mkUGFIFOF;
  FIFOF#(Vector#(n, Data)) respB <- mkFIFOF;
  FIFOF#(Vector#(n, Data)) respC <- mkFIFOF;
  Reg#(Bool) rfInit <- mkReg(False);
  Reg#(Bit#(FPRIndxSz)) rfInitPtr <- mkReg(0);

  (* fire_when_enabled *)
  rule init_BRAM(!rfInit);
    let gprReqA = BRAMRequest {
      write: True,
      responseOnWrite: False,
      address: {rfInitPtr, 1'b0},
      datain: 0
    };
    let gprReqB = BRAMRequest {
      write: True,
      responseOnWrite: False,
      address: {rfInitPtr, 1'b1},
      datain: 0
    };
    let fprReq = BRAMRequest {
      write: True,
      responseOnWrite: False,
      address: rfInitPtr,
      datain: 0
    };
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      rfiles[i].portA.request.put(gprReqA);
      rfiles[i].portB.request.put(gprReqB);
      fpr[i].portA.request.put(fprReq);
    end
    let nextPtr = rfInitPtr + 1;
    rfInitPtr <= nextPtr;
    rfInit <= nextPtr == 0;
  endrule

  (* fire_when_enabled *)
  rule req_BRAM(rfInit);
    match {.req, .wid} = reqs.first;
    match RFReq {write: .write, conv: .conv, rs1: .rs1, rs2: .rs2, rs3: .rs3, rd: .rd, mask: .mask, datas: .datas} = req;
    reqs.deq;
    let addrA = write ? rd : rs1;
    function BRAMRequest#(LaneRIndx, Data) gprReqA(Integer i) = BRAMRequest {
      write: write,
      responseOnWrite: False,
      address: {pack(addrA), wid},
      datain: datas[i]
    };
    BRAMRequest#(LaneRIndx, Data) gprReqB = BRAMRequest {
      write: False,
      responseOnWrite: False,
      address: {pack(rs2), wid},
      datain: 0
    };
    let addrF = write ? rd.idx : rs3.idx;
    function BRAMRequest#(FPRIndx, Data) fprReq(Integer i) = BRAMRequest {
      write: write,
      responseOnWrite: False,
      address: {addrF, wid},
      datain: datas[i]
    };

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      if (!write || (pack(rd) != 0 || conv) && unpack(mask[i])) begin
        rfiles[i].portA.request.put(gprReqA(i));
      end
      if (!write) begin
        rfiles[i].portB.request.put(gprReqB);
      end
      if (!write || rd.isFpr && unpack(mask[i])) begin
        fpr[i].portA.request.put(fprReq(i));
      end
    end
  endrule

  (* fire_when_enabled *)
  rule respA_BRAM;
    Vector#(n, Data) resp;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      let r <- rfiles[i].portA.response.get;
      resp[i] = r;
    end
    respA.enq(resp);
  endrule

  (* fire_when_enabled *)
  rule respB_BRAM;
    Vector#(n, Data) resp;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      let r <- rfiles[i].portB.response.get;
      resp[i] = r;
    end
    respB.enq(resp);
  endrule

  (* fire_when_enabled *)
  rule respC_BRAM;
    Vector#(n, Data) resp;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      let r <- fpr[i].portA.response.get;
      resp[i] = r;
    end
    respC.enq(resp);
  endrule

  method Action ask(RFReq#(n) req, Bit#(LocalWarpNum) wid);
    reqs.enq(tuple2(req, wid));
    if (!req.write) begin
      respAisZero.enq(pack(req.rs1) == 0);
      respBisZero.enq(!req.conv && pack(req.rs2) == 0);
    end
  endmethod

  // must be checked when enqueuing a read request
  method Bool notFull = respAisZero.notFull;

  method ActionValue#(RFResp#(n)) ans;
    let rv1 <- toGet(respA).get;
    let rv1isZero <- toGet(respAisZero).get;
    let rv2 <- toGet(respB).get;
    let rv2isZero <- toGet(respBisZero).get;
    let rv3 <- toGet(respC).get;
    if (rv1isZero) rv1 = replicate(0);
    if (rv2isZero) rv2 = replicate(0);
    return RFResp {rv1: rv1, rv2: rv2, rv3: rv3};
  endmethod
endmodule

(* synthesize *)
module mkVectorRFile(VectorRFile#(ThreadNum));
  let m <- mkVecRFile;
  return m;
endmodule

interface Scoreboard;
  method Action enq(RFRdReq req, RFCont cont);
  method Action deq(Bool write, Bit#(LocalWarpNum) wid, RIndx rd);
  method Tuple2#(RFRdReq, RFCont) first;
  method Bool notEmpty;
  // method Action clear;
endinterface


// The request/continuation pair plus the register bitmask decoded from it at
// enq time, so enq_out's wakeup test is the single AND (pending & srcMask).
// srcMask covers rs1/rs2/rs3 and the destination, the last being the WAW check.
typedef struct {
  RFRdReq  req;
  RFCont   cont;
  Bit#(64) srcMask;
} SbEntry deriving (Bits, Eq, FShow);

(* synthesize *)
module mkScoreboardIport(Fifo#(4, SbEntry));
  let m <- mkCFFifo(True, False);
  return m;
endmodule

(* synthesize *)
module mkScoreboard(Scoreboard);
  // Vortex-style scoreboard pipeline:
  //
  //   ibuf -> staged head -> registered ready -> cyclic grant -> out
  //
  // The hazard test and arbitration are in separate cycles.  The two-entry
  // output queue lets arbitration continue while the register-file consumer
  // drains the previous selection.
  Fifo#(2, Tuple2#(RFRdReq, RFCont)) out <- mkCFFifo(False, False);
  Vector#(WarpsPerBank, Fifo#(4, SbEntry)) ibuf <- replicateM(mkScoreboardIport);
  Vector#(WarpsPerBank, Reg#(Maybe#(SbEntry))) staged
    <- replicateM(mkReg(tagged Invalid));
  Vector#(WarpsPerBank, Reg#(Bool)) ready <- replicateM(mkReg(False));

  // Port 0 applies the writeback clear in the deq method.  The advance rule
  // reads and writes port 1, so it sees that clear, applies a simultaneous
  // destination reservation afterward, and computes replacement readiness
  // from the resulting next-state mask.  Reservation therefore wins over a
  // same-cycle clear, as in Vortex's inuse_regs_n update.
  Vector#(WarpsPerBank, Array#(Reg#(Bit#(64)))) pending
    <- replicateM(mkCReg(2, 0));

  // Readiness uses a one-cycle-old snapshot of the architecturally current
  // pending masks. This removes the same-cycle writeback-clear/completion path
  // from the ready registers. A consumed warp is forced unready below, so a
  // new reservation cannot be missed while the snapshot catches up.
  Vector#(WarpsPerBank, Reg#(Bit#(64))) pendingForReady
    <- replicateM(mkReg(0));

  // Vortex's cyclic arbiter first tries this cursor.  If that lane is not
  // ready, it falls back to the lowest ready lane.  countLSB is the balanced
  // implementation used by the proved Rocq mkFindIndex netlist.
  Reg#(Bit#(LocalWarpNum)) cursor <- mkReg(0);

  (* fire_when_enabled, no_implicit_conditions *)
  rule advance;
    Vector#(WarpsPerBank, Bit#(64)) pendingNext;
    Vector#(WarpsPerBank, Bool) requests;
    for (Integer i = 0; i < valueOf(WarpsPerBank); i = i + 1) begin
      pendingNext[i] = pending[i][1] & ~1;
      requests[i] = isValid(staged[i]) && ready[i];
    end

    Bit#(WarpsPerBank) requestBits = pack(requests);
    Bool grantValid = out.notFull && requestBits != 0;
    Bit#(LocalWarpNum) fallback = pack(countLSB(requestBits));
    Bit#(LocalWarpNum) grant = requests[cursor] ? cursor : fallback;

    if (grantValid) begin
      match SbEntry {req: .req, cont: .cont} = fromMaybe(?, staged[grant]);
      out.enq(tuple2(req, cont));
      cursor <= grant + 1;
    end

    for (Integer i = 0; i < valueOf(WarpsPerBank); i = i + 1) begin
      Bool consumed = grantValid && grant == fromInteger(i);
      if (consumed) begin
        let entry = fromMaybe(?, staged[i]);
        Bit#(64) dstMask = (1 << pack(entry.cont.dst)) & ~1;
        pendingNext[i] = pendingNext[i] | dstMask;
      end

      Maybe#(SbEntry) stageNext = staged[i];

      if (consumed || !isValid(staged[i])) begin
        if (ibuf[i].notEmpty) begin
          stageNext = tagged Valid ibuf[i].first;
          ibuf[i].deq;
        end else begin
          stageNext = tagged Invalid;
        end
      end

      staged[i] <= stageNext;
      if (consumed)
        ready[i] <= False;
      else if (stageNext matches tagged Valid .entry)
        ready[i] <= (pendingForReady[i] & entry.srcMask) == 0;
      else
        ready[i] <= False;
      pendingForReady[i] <= pendingNext[i] & ~1;
      pending[i][1] <= pendingNext[i] & ~1;
    end
  endrule

  method Action enq(RFRdReq req, RFCont cont);
    Bit#(LocalWarpNum) wid = truncateLSB(cont.warp.wid);
    Bit#(64) dstMask = 1 << pack(cont.dst);
    Bit#(64) srcMask = (1 << pack(req.rs1))
                     | (req.conv ? 0 : (1 << pack(req.rs2)))
                     | (req.rs3.isFpr ? (1 << {1'b1, req.rs3.idx}) : 0)
                     | dstMask;
    ibuf[wid].enq(SbEntry {req: req, cont: cont, srcMask: srcMask});
  endmethod

  // A read dequeue removes an instruction already reserved by advance.
  // Writeback clears through the early CReg port; advance observes that clear
  // while computing pendingNext and the next registered readiness values.
  method Action deq(Bool write, Bit#(LocalWarpNum) wid, RIndx rd);
    if (write) begin
      Bit#(64) clearMask = (1 << pack(rd)) & ~1;
      pending[wid][0] <= pending[wid][0] & ~clearMask;
    end else if (out.notEmpty) begin
      out.deq;
    end
  endmethod

  method first = out.first;
  method notEmpty = out.notEmpty;
endmodule

