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

// (32 (GPR) + 32 (FPR)) * (number of warps) ÷ 2 registers per lane
typedef TAdd#(5, LogWarpNum) LaneRIndxSz;
typedef TAdd#(4, LogWarpNum) FPRIndxSz;
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
  method Action ask(RFReq#(n) req, Bit#(TSub#(LogWarpNum, 1)) wid);
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
  FIFOF#(Tuple2#(RFReq#(n), Bit#(TSub#(LogWarpNum, 1)))) reqs <- mkLFIFOF;
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

  method Action ask(RFReq#(n) req, Bit#(TSub#(LogWarpNum, 1)) wid);
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
  method Action deq(Bool write, Bit#(TSub#(LogWarpNum, 1)) wid, RIndx rd);
  method Tuple2#(RFRdReq, RFCont) first;
  method Bool notEmpty;
  // method Action clear;
endinterface

typedef TDiv#(WarpNum, 2) WarpsPerBank;

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
  // The CReg ports carry the intra-cycle schedule: first/notEmpty/deq use
  // port 0, enq_out uses port 1, so enq_out sees deq's clear of out and its
  // set of pending in the same cycle.  pending has to be a CReg for that: a
  // plain register would let an enq_out firing in the cycle a read-deq retires
  // pick a second entry from that lane against a pending that does not yet
  // hold the retiring destination.
  Reg#(Maybe#(Tuple2#(RFRdReq, RFCont))) out[2] <- mkCReg(2, tagged Invalid);
  Vector#(WarpsPerBank, Fifo#(4, SbEntry)) ibuf <- replicateM(mkScoreboardIport);
  Vector#(WarpsPerBank, Array#(Reg#(Bit#(64)))) pending <- replicateM(mkCReg(2, 0));

  (* fire_when_enabled, no_implicit_conditions *)
  rule enq_out(!isValid(out[1]));
    Vector#(WarpsPerBank, Bool) isReady;
    for (Integer i = 0; i < valueOf(WarpsPerBank); i = i + 1)
      isReady[i] = ibuf[i].notEmpty && (pending[i][1] & ibuf[i].first.srcMask) == 0;

    if (findIndex(id, isReady) matches tagged Valid .idx) begin
      out[1] <= tagged Valid tuple2(ibuf[idx].first.req, ibuf[idx].first.cont);
      ibuf[idx].deq;
    end
  endrule

  method Action enq(RFRdReq req, RFCont cont);
    Bit#(TSub#(LogWarpNum, 1)) wid = cont.warp.wid[valueOf(LogWarpNum)-1 : 1];
    Bit#(64) dstMask = 1 << pack(cont.dst);
    Bit#(64) srcMask = (1 << pack(req.rs1))
                     | (req.conv ? 0 : (1 << pack(req.rs2)))
                     | (req.rs3.isFpr ? (1 << {1'b1, req.rs3.idx}) : 0)
                     | dstMask;
    ibuf[wid].enq(SbEntry {req: req, cont: cont, srcMask: srcMask});
  endmethod

  // pending is set when the continuation retires: the write branch clears rd,
  // the read branch sets the retiring destination.
  method Action deq(Bool write, Bit#(TSub#(LogWarpNum, 1)) wid, RIndx rd);
    let ne = isValid(out[0]);
    match {.*, .cont} = fromMaybe(?, out[0]);
    let idx = write ? wid : cont.warp.wid[valueOf(LogWarpNum)-1 : 1];
    let cur = pending[idx][0];
    // if !write && !ne, (ne << cont.dst) == 0, so pending[idx] doesn't change;
    // if cont.dst == 0, it is cleared out anyway
    let nxt = write ? cur & ~(1 << pack(rd))
                    : cur | (extend(pack(ne)) << pack(cont.dst));
    pending[idx][0] <= nxt & ~1;
    if (!write && ne)
      out[0] <= tagged Invalid;
  endmethod

  method first = fromMaybe(?, out[0]);
  method notEmpty = isValid(out[0]);
endmodule

