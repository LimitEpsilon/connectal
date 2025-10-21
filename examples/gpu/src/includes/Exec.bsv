/*

Copyright (C) 2012

Arvind <arvind@csail.mit.edu>
Derek Chiou <derek@ece.utexas.edu>
Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Types::*;
import ProcTypes::*;
import Vector::*;
import FIFOF::*;
import Fifo::*;
import SpecialFIFOs::*;
import MulDiv::*;

typedef function Data a(Data x, Data y, AluFunc f) ScalarAlu;

(* noinline *)
function Data alu(Data a, Data b, AluFunc func);
  Data res = case (func)
    Add   : (a + b);
    Sub   : (a - b);
    And   : (a & b);
    Or    : (a | b);
    Xor   : (a ^ b);
    Slt   : zeroExtend(pack(signedLT(a, b)));
    Sltu  : zeroExtend(pack(a < b));
	  // 5-bit shift width for 32-bit data
    Sll   : (a << b[4:0]);
    Srl   : (a >> b[4:0]);
    Sra   : signedShiftRight(a, b[4:0]);
    Ceqz  : b == 0 ? 0 : a;
    Cnez  : b == 0 ? a : 0;
  endcase;
  return res;
endfunction

typedef function Bool b(Data x, Data y, BrFunc f) ScalarBru;

(* noinline *)
function Bool bru(Data a, Data b, BrFunc brFunc);
  Bool brTaken = case (brFunc)
    Eq  : (a == b);
    Neq : (a != b);
    Lt  : signedLT(a, b);
    Ltu : (a < b);
    Ge  : signedGE(a, b);
    Geu : (a >= b);
    AT  : True;
    NT  : False;
  endcase;
  return brTaken;
endfunction

typedef struct {
  AluFunc f;
  Vector#(n, Data) v1;
  Vector#(n, Data) v2;
} AluReq#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorAlu#(numeric type n);
  method Action enq(AluReq#(n) req);
  method Bool notEmpty;
  method Vector#(n, Data) first;
  method Action deq;
  method Action clear;
endinterface

(* synthesize *)
module mkVectorAlu(VectorAlu#(ThreadNum));
  Vector#(n, ScalarAlu) alus = replicate(alu);
  FIFOF#(AluReq#(ThreadNum)) reqs <- mkBypassFIFOF;
  FIFOF#(Vector#(ThreadNum, Data)) resps <- mkLFIFOF;
  Reg#(Bool) noClear <- mkReg(True);

  (* fire_when_enabled *)
  rule compute_resp;
    $display("compute_resp");
    let r = reqs.first;
    reqs.deq;
    function Data app(ScalarAlu a, Data v1, Data v2) = a(v1, v2, r.f);
    resps.enq(zipWith3(app, alus, r.v1, r.v2));
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    reqs.clear;
    resps.clear;
    noClear <= True;
  endrule

  method Action enq(AluReq#(ThreadNum) req); reqs.enq(req); endmethod
  method Bool notEmpty = resps.notEmpty;
  method Vector#(ThreadNum, Data) first = resps.first;
  method Action deq; resps.deq; endmethod
  method Action clear if (noClear); noClear <= False; endmethod
endmodule

typedef struct {
  Bit#(2) f;
  Vector#(n, Data) v1;
  Vector#(n, Data) v2;
} MulReq#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorMul#(numeric type n);
  method Action enq(MulReq#(n) req);
  method Bool notEmpty;
  method Vector#(n, Data) first;
  method Action deq;
  method Action clear;
endinterface

(* synthesize *)
module mkVectorMul(VectorMul#(ThreadNum));
  Vector#(ThreadNum, Mul32) muls <- replicateM(mkMul32);
  FIFOF#(MulReq#(ThreadNum)) reqs <- mkBypassFIFOF;
  Fifo#(5, Bool) respLower <- mkLatencyFifo(True, True);
  FIFOF#(Vector#(ThreadNum, Data)) resps <- mkBypassFIFOF;
  Reg#(Bool) noClear <- mkReg(True);
  let req = reqs.notEmpty ? reqs.first : ?;

  (* fire_when_enabled *)
  rule process_req(reqs.notEmpty); // relies on the fact that resps are promptly dequeued
    Tuple2#(Bool, Bool) sign = case (req.f)
      2'b00: // MUL
        tuple2(True, True);
      2'b01: // MULH
        tuple2(True, True);
      2'b10: // MULHSU
        tuple2(True, False);
      2'b11: // MULHU
        tuple2(False, False);
    endcase;
    Bool lower = req.f == 2'b00; // take lower half
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1)
      muls[i].enq(tpl_1(sign), req.v1[i], tpl_2(sign), req.v2[i]);
    respLower.enq(lower);
    reqs.deq;
  endrule

  (* fire_when_enabled *)
  rule compute_resp(respLower.notEmpty);
    Vector#(ThreadNum, Data) res;
    Bool lower = respLower.first; // take lower half
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1) begin
      res[i] = lower ? muls[i].first[31:0] : muls[i].first[63:32];
      muls[i].deq;
    end
    resps.enq(res);
    respLower.deq;
    $display("compute_resp_mul");
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    reqs.clear;
    respLower.clear;
    resps.clear;
    noClear <= True;
  endrule

  method Action enq(MulReq#(ThreadNum) x); reqs.enq(x); endmethod
  method Bool notEmpty = resps.notEmpty;
  method Vector#(ThreadNum, Data) first = resps.first;
  method Action deq; resps.deq; endmethod
  method Action clear if (noClear);
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1)
      muls[i].clear; // gets cleared after one clock cycle
    noClear <= False;
  endmethod
endmodule

typedef struct {
  Bit#(2) f;
  Vector#(n, Data) v1;
  Vector#(n, Data) v2;
} DivReq#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorDiv#(numeric type n);
  method Action enq(DivReq#(n) req);
  method Bool notEmpty;
  method Vector#(n, Data) first;
  method Action deq;
  method Action clear;
endinterface

(* synthesize *)
module mkVectorDiv(VectorDiv#(ThreadNum));
  Vector#(ThreadNum, Div32) divs <- replicateM(mkDiv32);
  FIFOF#(DivReq#(ThreadNum)) reqs <- mkBypassFIFOF;
  Fifo#(TAdd#(1, DivStage), Bool) respQuot <- mkLatencyFifo(True, True);
  FIFOF#(Vector#(ThreadNum, Data)) resps <- mkBypassFIFOF;
  Reg#(Bool) noClear <- mkReg(True);
  let req = reqs.notEmpty ? reqs.first : ?;

  (* fire_when_enabled *)
  rule process_req(reqs.notEmpty);
    Bool sign = !unpack(req.f[0]); // 1'b1 for divu/remu
    Bool quot = !unpack(req.f[1]); // 1'b1 for rem/remu
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1)
      divs[i].enq(sign, req.v1[i], sign, req.v2[i]);
    respQuot.enq(quot);
    reqs.deq;
  endrule

  (* fire_when_enabled *)
  rule compute_resp(respQuot.notEmpty);
    Vector#(ThreadNum, Data) res;
    Bool quot = respQuot.first; // 1'b1 for rem/remu
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1) begin
      match {.q, .r} = divs[i].first;
      res[i] = quot ? q : r;
      // TODO: fuse consecutive operations
      divs[i].deq;
    end
    resps.enq(res);
    respQuot.deq;
    $display("compute_resp_div");
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    reqs.clear;
    respQuot.clear;
    resps.clear;
    noClear <= True;
  endrule

  method Action enq(DivReq#(ThreadNum) x); reqs.enq(x); endmethod
  method Bool notEmpty = resps.notEmpty;
  method Vector#(ThreadNum, Data) first = resps.first;
  method Action deq; resps.deq; endmethod
  method Action clear if (noClear);
    for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1)
      divs[i].clear; // gets cleared after one clock cycle
    noClear <= False;
  endmethod
endmodule

typedef struct {
  BrFunc f;
  Vector#(n, Data) v1;
  Vector#(n, Data) v2;
} BruReq#(numeric type n) deriving (Bits, Eq, FShow);

interface VectorBru#(numeric type n);
  method Action enq(BruReq#(n) req);
  method Bool notEmpty;
  method Vector#(n, Bool) first;
  method Action deq;
  method Action clear;
endinterface

(* synthesize *)
module mkVectorBru(VectorBru#(ThreadNum));
  Vector#(ThreadNum, ScalarBru) brus = replicate(bru);
  FIFOF#(BruReq#(ThreadNum)) reqs <- mkBypassFIFOF;
  FIFOF#(Vector#(ThreadNum, Bool)) resps <- mkLFIFOF;
  Reg#(Bool) noClear <- mkReg(True);

  (* fire_when_enabled *)
  rule compute_resp;
    let r = reqs.first;
    reqs.deq;
    function Bool app(ScalarBru b, Data v1, Data v2) = b(v1, v2, r.f);
    resps.enq(zipWith3(app, brus, r.v1, r.v2));
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    reqs.clear;
    resps.clear;
    noClear <= True;
  endrule

  method Action enq(BruReq#(ThreadNum) x); reqs.enq(x); endmethod
  method Bool notEmpty = resps.notEmpty;
  method Vector#(ThreadNum, Bool) first = resps.first;
  method Action deq; resps.deq; endmethod
  method Action clear if (noClear);
    noClear <= False;
  endmethod
endmodule

