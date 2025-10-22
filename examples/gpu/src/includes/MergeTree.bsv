// Adapted from https://github.com/mtikekar/advanced_bsv
import Vector :: *;
import GetPut :: *;
import FIFOF  :: *;

interface MergeTree#(numeric type n, type t);
  interface Vector#(n, Put#(t)) iport;
  method Action deq;
  method Action clear;
  method t first;
  method Bool notEmpty;
endinterface

module mkMergeTree(MergeTree#(n, t)) provisos (Bits#(t, tSz));
  (* hide *) Reg#(Bool) noClear <- mkReg(True);
  Reg#(Bool) cur <- mkReg(True);
  Vector#(n, Reg#(Bool)) epochs <- replicateM(mkReg(True));
  Vector#(n, FIFOF#(t)) iports <- replicateM(mkUGFIFOF);
  Vector#(n, Put#(t)) inner;
  Vector#(n, Bool) validT;
  Vector#(n, Bool) validF;

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    validT[i] = iports[i].notEmpty && epochs[i];

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    validF[i] = iports[i].notEmpty && !epochs[i];

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    inner[i] =
      interface Put;
        method Action put(x) if (noClear && iports[i].notFull);
          iports[i].enq(x);
        endmethod
      endinterface;

  let idxT = findIndex(id, validT);
  let idxF = findIndex(id, validF);
  let idx = case (tuple2(idxT, idxF)) matches
    {tagged Valid .iT, tagged Valid .iF}: cur ? iT : iF;
    {tagged Valid .iT, tagged Invalid}: iT;
    {tagged Invalid, tagged Valid .iF}: iF;
    {tagged Invalid, tagged Invalid}: ?;
  endcase;
  let rdy = isValid(idxT) || isValid(idxF);

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      iports[i].clear;
      epochs[i] <= True;
    end
    noClear <= True;
    cur <= True;
  endrule

  interface iport = inner;
  method Action deq if (noClear && rdy);
    let e = isValid(idxT) && (!isValid(idxF) || cur);
    iports[idx].deq;
    epochs[idx] <= !e;
    cur <= e;
  endmethod
  method first if (rdy) = iports[idx].first;
  method notEmpty = rdy;
  method Action clear if (noClear); noClear <= False; endmethod
endmodule

