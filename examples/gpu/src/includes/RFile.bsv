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

// 32 * (number of warps) ÷ 2 registers per lane
typedef TAdd#(4, LogWarpNum) LaneRIndxSz;
typedef Bit#(LaneRIndxSz) LaneRIndx;
typedef TExp#(LaneRIndxSz) RegPerLane;

typedef struct {
  Bool    conv;
  RIndx   rs1;
  RIndx   rs2;
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
  RIndx   rd;
  Bit#(n) mask;
  Vector#(n, Data) datas;
} RFReq#(numeric type n) deriving (Bits, Eq, FShow);

function RFReq#(ThreadNum) fromRdReq(RFRdReq req);
  match RFRdReq {conv: .conv, rs1: .rs1, rs2: .rs2} = req;
  return RFReq {
    write: False, conv: conv, rs1: rs1, rs2: rs2, rd: ?, mask: ?, datas: ?
  };
endfunction

function RFReq#(n) fromWrReq(RFWrReq#(n) req);
  match RFWrReq {conv: .conv, rd: .rd, mask: .mask, datas: .datas} = req;
  return RFReq {
    write: True, conv: conv, rs1: ?, rs2: ?, rd: rd, mask: mask, datas: datas
  };
endfunction

typedef struct {
  Vector#(n, Data) rv1;
  Vector#(n, Data) rv2;
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

module mkVecRFile(VectorRFile#(n));
  Vector#(n, BRAM2Port#(LaneRIndx, Data)) rfiles <- replicateM(mkRFileBRAM);
  Fifo#(4, Tuple2#(RFReq#(n), Bit#(TSub#(LogWarpNum, 1)))) reqs <- mkBRAMFifo(True, True);
  FIFOF#(Bool) respAisZero <- mkGFIFOF(False, True);
  FIFOF#(Vector#(n, Data)) respA <- mkBypassFIFOF;
  FIFOF#(Bool) respBisZero <- mkGFIFOF(False, True);
  FIFOF#(Vector#(n, Data)) respB <- mkBypassFIFOF;
  Reg#(Bool) noClear <- mkReg(True);

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      rfiles[i].portAClear;
      rfiles[i].portBClear;
    end
    reqs.clear;
    respAisZero.clear;
    respA.clear;
    respBisZero.clear;
    respB.clear;
    noClear <= True;
  endrule

  (* fire_when_enabled *)
  rule req_BRAM;
    match {.req, .wid} = reqs.first;
    match RFReq {write: .write, conv: .conv, rs1: .rs1, rs2: .rs2, rd: .rd, mask: .mask, datas: .datas} = req;
    reqs.deq;
    if (write) begin
      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        if ((rd != 0 || conv) && unpack(mask[i]))
          rfiles[i].portA.request.put(BRAMRequest {
            write: True,
            responseOnWrite: False,
            address: {rd, wid},
            datain: datas[i]
          });
      end
    end else begin
      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        rfiles[i].portA.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: {rs1, wid},
          datain: ?
        });
        rfiles[i].portB.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: {conv ? 0 : rs2, wid},
          datain: ?
        });
      end
      respAisZero.enq(rs1 == 0);
      respBisZero.enq(!conv && rs2 == 0);
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

  method Action ask(RFReq#(n) req, Bit#(TSub#(LogWarpNum, 1)) wid);
    reqs.enq(tuple2(req, wid));
  endmethod

  method ActionValue#(RFResp#(n)) ans;
    let rv1 = respA.first;
    let rv1isZero = respAisZero.first;
    let rv2 = respB.first;
    let rv2isZero = respBisZero.first;
    respA.deq;
    respAisZero.deq;
    respB.deq;
    respBisZero.deq;
    if (rv1isZero) rv1 = replicate(0);
    if (rv2isZero) rv2 = replicate(0);
    return RFResp {rv1: rv1, rv2: rv2};
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
module mkScoreboard(Scoreboard);
  // The correctness of this module depends on the output FIFO containing only one continuation
  // This is because we update the pending register when the continuation is dequeued
  (* hide *) Reg#(Maybe#(Tuple2#(RFRdReq, RFCont))) out[2] <- mkCReg(2, tagged Invalid);
  (* hide *) Vector#(TDiv#(WarpNum, 2), Fifo#(4, Tuple2#(RFRdReq, RFCont))) ibuf <- replicateM(mkBRAMFifo(False, False));
  (* hide *) Vector#(TDiv#(WarpNum, 2), Reg#(Bit#(32))) pending <- replicateM(mkReg(0));
  Reg#(Bool) noClear <- mkReg(True);
  Vector#(TDiv#(WarpNum, 2), Put#(Tuple2#(RFRdReq, RFCont))) inner;

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1)
    inner[i] =
      interface Put;
        method Action put(x) if (ibuf[i].notFull) = ibuf[i].enq(x);
      endinterface;

  (* fire_when_enabled, no_implicit_conditions *)
  rule enq_out(!isValid(out[0]));
    function Bool genIdx(Integer i);
      match {.req, .cont} = ibuf[i].first;
      Bool rs1Pending = unpack(pending[i][req.rs1]);
      Bool rs2Pending = !req.conv && unpack(pending[i][req.rs2]);
      Bool dstPending = unpack(pending[i][cont.dst]);
      return ibuf[i].notEmpty && !rs1Pending && !rs2Pending && !dstPending;
    endfunction
    Vector#(TDiv#(WarpNum, 2), Bool) isReady = genWith(genIdx);
    let idx = findIndex(id, isReady);
    if (idx matches tagged Valid .i) begin
      out[0] <= tagged Valid ibuf[i].first;
      ibuf[i].deq;
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
      ? curPending & ~(1 << rd)
      : curPending | (extend(pack(notEmpty)) << cont.dst);
    pending[idx] <= {nextPending[31 : 1], 1'b0};
    if (!write && notEmpty)
      out[1] <= tagged Invalid;
  endmethod
  method first if (isValid(out[1])) = fromMaybe(?, out[1]);
  method notEmpty = isValid(out[1]);
  method Action clear if (noClear); noClear <= False; endmethod
endmodule

