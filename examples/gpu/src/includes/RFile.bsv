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
import BRAM::*;
import MergeTree::*;

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
  Bit#(TSub#(LogWarpNum, 1))  wid;
  Bit#(n) mask;
  Vector#(n, Data) datas;
} RFWrReq#(numeric type n) deriving (Bits, Eq, FShow);

typedef struct {
  Bool    write;
  Bool    conv;
  RIndx   rs1;
  RIndx   rs2;
  RIndx   rd;
  Bit#(TSub#(LogWarpNum, 1))  wid;
  Bit#(n) mask;
  Vector#(n, Data) datas;
} RFReq#(numeric type n) deriving (Bits, Eq, FShow);

function RFReq#(ThreadNum) fromRdReq(RFRdReq req, RFCont cont);
  match RFRdReq {conv: .conv, rs1: .rs1, rs2: .rs2} = req;
  match RFCont {warp: .warp} = cont;
  match Warp {wid: .wid, mask: .mask} = warp;
  Bit#(TSub#(LogWarpNum, 1)) upperWid = wid[valueOf(LogWarpNum)-1 : 1];
  return RFReq {
    write: False, conv: conv, rs1: rs1, rs2: rs2, rd: ?, wid: upperWid, mask: mask, datas: ?
  };
endfunction

function RFReq#(n) fromWrReq(RFWrReq#(n) req);
  match RFWrReq {conv: .conv, rd: .rd, wid: .wid, mask: .mask, datas: .datas} = req;
  return RFReq {
    write: True, conv: conv, rs1: ?, rs2: ?, rd: rd, wid: wid, mask: mask, datas: datas
  };
endfunction

typedef struct {
  Vector#(n, Data) rv1;
  Vector#(n, Data) rv2;
} RFResp#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorRFile#(numeric type n);
  interface Put#(RFReq#(n)) ask;
  interface Get#(RFResp#(n)) ans;
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
	FIFOF#(RFReq#(n)) reqs <- mkBypassFIFOF;
	FIFOF#(Bool) respAisZero <- mkLFIFOF;
	FIFOF#(Vector#(n, Data)) respA <- mkBypassFIFOF;
	FIFOF#(Bool) respBisZero <- mkLFIFOF;
	FIFOF#(Vector#(n, Data)) respB <- mkBypassFIFOF;

  (* fire_when_enabled *)
  rule req_BRAM;
    match RFReq {write: .write, conv: .conv, rs1: .rs1, rs2: .rs2, rd: .rd, mask: .mask, wid: .wid, datas: .datas} = reqs.first;
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

  interface ask =
    interface Put;
      method Action put(RFReq#(n) req);
        reqs.enq(req);
      endmethod
    endinterface;

  interface ans =
    interface Get;
      method ActionValue#(RFResp#(n)) get;
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
    endinterface;
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
endinterface

(* synthesize *)
module mkScoreboard(Scoreboard);
  (* hide *) Reg#(Maybe#(Tuple2#(RFRdReq, RFCont))) out[2] <- mkCReg(2, tagged Invalid);
  (* hide *) Vector#(TDiv#(WarpNum, 2), Reg#(Tuple2#(RFRdReq, RFCont))) ibuf <- replicateM(mkRegU);
  (* hide *) Reg#(Bool) cur[2] <- mkCReg(2, False); // current epoch
  (* hide *) Vector#(TDiv#(WarpNum, 2), Reg#(Bit#(32))) pending <- replicateM(mkReg(0));
  Vector#(TDiv#(WarpNum, 2), Array#(Reg#(Epoch))) iports <-
    replicateM(mkCReg(2, Epoch {epoch: False, valid: False}));
  Vector#(TDiv#(WarpNum, 2), Put#(Tuple2#(RFRdReq, RFCont))) inner;
  Vector#(TDiv#(WarpNum, 2), Bool) isPending;
  Vector#(TDiv#(WarpNum, 2), Bool) epochF;
  Vector#(TDiv#(WarpNum, 2), Bool) epochT;

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1) begin
    match {.req, .cont} = ibuf[i];
    Bool rs1Pending = unpack(pending[i][req.rs1]);
    Bool rs2Pending = !req.conv && unpack(pending[i][req.rs2]);
    Bool dstPending = unpack(pending[i][cont.dst]);
    isPending[i] = rs1Pending || rs2Pending || dstPending;
  end

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1) begin
    match Epoch {epoch: .epoch, valid: .valid} = iports[i][0];
    epochF[i] = epoch ? False : valid && !isPending[i];
  end

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1) begin
    match Epoch {epoch: .epoch, valid: .valid} = iports[i][0];
    epochT[i] = epoch ? valid && !isPending[i] : False;
  end

  for (Integer i = 0; i < valueOf(WarpNum) / 2; i = i + 1)
    inner[i] =
      interface Put;
        method Action put(x) if (!iports[i][1].valid);
          iports[i][1] <= Epoch {epoch: !cur[1], valid: True};
          ibuf[i] <= x;
        endmethod
      endinterface;

  (* fire_when_enabled, no_implicit_conditions *)
  rule enq_out(!isValid(out[0]));
    let idxF = findIndex(id, epochF);
    let idxT = findIndex(id, epochT);
    let idx =
      case (tuple2(idxF, idxT)) matches
        {tagged Valid .iF, tagged Valid .iT}: cur[0] ? iT : iF;
        {tagged Valid .iF, tagged Invalid}: iF;
        {tagged Invalid, tagged Valid .iT}: iT;
        default: 0;
      endcase;
    if (isValid(idxF) || isValid(idxT)) begin
      iports[idx][0].valid <= False;
      out[0] <= tagged Valid ibuf[idx];
    end
    if (!isValid(idxF) || !isValid(idxT))
      cur[0] <= isValid(idxT);
  endrule

  interface iport = inner;
  method Action deq(Bool write, Bit#(TSub#(LogWarpNum, 1)) wid, RIndx rd);
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
endmodule

