import Vector :: *;
import GetPut :: *;
import FIFOF  :: *;

interface MergeTree#(numeric type n, type t);
  interface Vector#(n, Put#(t)) iport;
  method Action deq;
  method t first;
  method Bool notEmpty;
endinterface

module mkMergeTree(MergeTree#(n, t)) provisos (Bits#(t, tSz));
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
        method Action put(x) if (iports[i].notFull);
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
  let rdyT = any(id, validT);
  let rdyF = any(id, validF);
  let rdy = rdyT || rdyF;

  interface iport = inner;
  method Action deq if (rdy);
    let e = rdyT && (!rdyF || cur);
    iports[idx].deq;
    epochs[idx] <= !e;
    cur <= e;
  endmethod
  method first if (rdy) = iports[idx].first;
  method notEmpty = rdy;
endmodule

