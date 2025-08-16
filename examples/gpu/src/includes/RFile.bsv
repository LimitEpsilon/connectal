/*

Copyright (C) 2012 Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

// Correct use of the register file implies that the same index can't be used for simultaneous read and write from different rules. If different indices are used reads and writes are conflict free. If the reads and writes are in the same rule, write updates the file at the end of the rule.
// We have imitated this conflict free behavior using config regs.
// If we had used ordinary registers, then read<write
// In many designs where we needed Bypass register file, the bypassing was implemented outside the register file, explicitly.

import Types::*;
import ProcTypes::*;
import Vector::*;
import FIFOF::*;
import SpecialFIFOs::*;
import BRAM::*;

// 32 * (number of warps) ÷ 2 registers per lane
typedef TAdd#(4, LogWarpNum) LaneRIndxSz;
typedef Bit#(LaneRIndxSz) LaneRIndx;
typedef TExp#(LaneRIndxSz) RegPerLane;

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
        if (rd != 0 && unpack(mask[i]))
          rfiles[i].portA.request.put(BRAMRequest {
            write: True,
            responseOnWrite: False,
            address: {conv ? 0 : rd, wid},
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

