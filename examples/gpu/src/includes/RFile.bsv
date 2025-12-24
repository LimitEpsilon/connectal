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
  method ActionValue#(RFResp#(n)) ans;
  method Action clear;
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
  Fifo#(4, Tuple2#(RFReq#(n), Bit#(TSub#(LogWarpNum, 1)))) reqs <- mkBRAMFifo(True, True);
  FIFOF#(Bool) respAisZero <- mkGFIFOF(False, True);
  FIFOF#(Vector#(n, Data)) respA <- mkBypassFIFOF;
  FIFOF#(Bool) respBisZero <- mkGFIFOF(False, True);
  FIFOF#(Vector#(n, Data)) respB <- mkBypassFIFOF;
  FIFOF#(Vector#(n, Data)) respC <- mkBypassFIFOF;
  Reg#(Bool) noClear <- mkReg(True);

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      rfiles[i].portAClear;
      rfiles[i].portBClear;
      fpr[i].portAClear;
    end
    reqs.clear;
    respAisZero.clear;
    respA.clear;
    respBisZero.clear;
    respB.clear;
    respC.clear;
    noClear <= True;
  endrule

  (* fire_when_enabled *)
  rule req_BRAM;
    match {.req, .wid} = reqs.first;
    match RFReq {write: .write, conv: .conv, rs1: .rs1, rs2: .rs2, rs3: .rs3, rd: .rd, mask: .mask, datas: .datas} = req;
    reqs.deq;
    if (write) begin
      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        if ((pack(rd) != 0 || conv) && unpack(mask[i]))
          rfiles[i].portA.request.put(BRAMRequest {
            write: True,
            responseOnWrite: False,
            address: {pack(rd), wid},
            datain: datas[i]
          });
        if (rd.isFpr && unpack(mask[i]))
          fpr[i].portA.request.put(BRAMRequest {
            write: True,
            responseOnWrite: False,
            address: {rd.idx, wid},
            datain: datas[i]
          });
      end
    end else begin
      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        rfiles[i].portA.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: {pack(rs1), wid},
          datain: ?
        });
        rfiles[i].portB.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: {conv ? 0 : pack(rs2), wid},
          datain: ?
        });
        fpr[i].portA.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: {rs3.idx, wid},
          datain: ?
        });
      end
      respAisZero.enq(pack(rs1) == 0);
      respBisZero.enq(!conv && pack(rs2) == 0);
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
  endmethod

  method ActionValue#(RFResp#(n)) ans;
    let rv1 = respA.first;
    let rv1isZero = respAisZero.first;
    let rv2 = respB.first;
    let rv2isZero = respBisZero.first;
    let rv3 = respC.first;
    respA.deq;
    respAisZero.deq;
    respB.deq;
    respBisZero.deq;
    respC.deq;
    if (rv1isZero) rv1 = replicate(0);
    if (rv2isZero) rv2 = replicate(0);
    return RFResp {rv1: rv1, rv2: rv2, rv3: rv3};
  endmethod

  method Action clear if (noClear); noClear <= False; endmethod
endmodule

(* synthesize *)
module mkVectorRFile(VectorRFile#(ThreadNum));
  let m <- mkVecRFile;
  return m;
endmodule

interface Scoreboard;
  interface Vector#(TDiv#(WarpNum, 2), Put#(Tuple2#(RFRdReq, RFCont))) iport;
  method Action deq(Bool write, Bit#(TSub#(LogWarpNum, 1)) wid, RIndx rd);
  method Tuple2#(RFRdReq, RFCont) first;
  method Bool notEmpty;
  method Action clear;
endinterface

(* synthesize *)
module mkScoreboardIport(Fifo#(4, Tuple2#(RFRdReq, RFCont)));
  let m <- mkCFFifo(False, False);
  return m;
endmodule

(* synthesize *)
module mkScoreboard(Scoreboard);
  // The correctness of this module depends on the output FIFO containing only one continuation
  // This is because we update the pending register when the continuation is dequeued
  Reg#(Maybe#(Tuple2#(RFRdReq, RFCont))) out[2] <- mkCReg(2, tagged Invalid);
  Vector#(TDiv#(WarpNum, 2), Fifo#(4, Tuple2#(RFRdReq, RFCont))) ibuf <- replicateM(mkScoreboardIport);
  Vector#(TDiv#(WarpNum, 2), Reg#(Bit#(64))) pending <- replicateM(mkReg(0));
  Reg#(Bool) noClear <- mkReg(True);
  Vector#(TDiv#(WarpNum, 2), Put#(Tuple2#(RFRdReq, RFCont))) inner;

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1)
    inner[i] =
      interface Put;
        method Action put(x) if (ibuf[i].notFull) = ibuf[i].enq(x);
      endinterface;

  (* fire_when_enabled, no_implicit_conditions *)
  rule enq_out(!isValid(out[0]));
    Vector#(TDiv#(WarpNum, 2), Bool) isReady;
    for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1) begin
      match {.req, .cont} = ibuf[i].first;
      Bool rs1Pending = unpack(pending[i][pack(req.rs1)]);
      Bool rs2Pending = !req.conv && unpack(pending[i][pack(req.rs2)]);
      Bit#(32) fpr = pending[i][63:32];
      Bool rs3Pending = req.rs3.isFpr && unpack(fpr[req.rs3.idx]);
      Bool dstPending = unpack(pending[i][pack(cont.dst)]);
      //  if (ibuf[i].notEmpty && rs1Pending)
      //    $display("WID %d, rs1: %d locked", i, pack(req.rs1));
      //  if (ibuf[i].notEmpty && rs2Pending)
      //    $display("WID %d, rs2: %d locked", i, pack(req.rs2));
      //  if (ibuf[i].notEmpty && rs3Pending)
      //    $display("WID %d, rs3: %d locked", i, req.rs3.idx);
      //  if (ibuf[i].notEmpty && dstPending)
      //    $display("WID %d, rd: %d locked", i, pack(cont.dst));
      isReady[i] = ibuf[i].notEmpty && !rs1Pending && !rs2Pending && !rs3Pending && !dstPending;
    end
    let idx = fromMaybe(?, findIndex(id, isReady));
    if (any(id, isReady)) begin
      out[0] <= tagged Valid ibuf[idx].first;
      ibuf[idx].deq;
    end
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    out[1] <= tagged Invalid;
    for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1) begin
      ibuf[i].clear;
      pending[i] <= 0;
    end
    noClear <= True;
  endrule

  interface iport = inner;
  method Action deq(Bool write, Bit#(TSub#(LogWarpNum, 1)) wid, RIndx rd) if (noClear);
    let notEmpty = isValid(out[1]);
    match {.req, .cont} = fromMaybe(?, out[1]);
    let idx = write ? wid : cont.warp.wid[valueOf(LogWarpNum)-1 : 1];
    let curPending = pending[idx];
    // if !write && !notEmpty, (notEmpty << cont.dst) == 0, so pending[idx] doesn't change
    // if cont.dst == 0, it is cleared out anyway
    let nextPending =
      write
      ? curPending & ~(1 << pack(rd))
      : curPending | (extend(pack(notEmpty)) << pack(cont.dst));
    pending[idx] <= nextPending & ~1;
    if (!write && notEmpty)
      out[1] <= tagged Invalid;
  endmethod
  method first if (isValid(out[1])) = fromMaybe(?, out[1]);
  method notEmpty = isValid(out[1]);
  method Action clear if (noClear); noClear <= False; endmethod
endmodule

