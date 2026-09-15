import Vector :: *;
import GetPut :: *;
import FIFOF  :: *;

interface MergeTree#(numeric type n, type t);
  interface Vector#(n, Put#(t)) iport;
  method Action deq;
  method t first;
  method Bool notEmpty;
endinterface

// Two-entry pipeline FIFOF implemented with CReg ordering. Port 0 removes the
// head; port 1 observes that removal and can install a replacement in the same
// cycle. This retains mkUGFIFOF's capacity while avoiding its pointer-selected
// data write on the timing-sensitive sequential-fetch return.
module mkCRegPipelineFIFOF(FIFOF#(t)) provisos (Bits#(t, tSz));
  Reg#(Maybe#(t)) head[2] <- mkCReg(2, tagged Invalid);
  Reg#(Maybe#(t)) tail[2] <- mkCReg(2, tagged Invalid);

  method Bool notFull = !isValid(tail[1]);

  method Action enq(t x) if (!isValid(tail[1]));
    if (isValid(head[1]))
      tail[1] <= tagged Valid x;
    else
      head[1] <= tagged Valid x;
  endmethod

  method Bool notEmpty = isValid(head[0]);

  method Action deq if (isValid(head[0]));
    head[0] <= tail[0];
    tail[0] <= tagged Invalid;
  endmethod

  method t first if (head[0] matches tagged Valid .x);
    return x;
  endmethod

  method Action clear;
    head[1] <= tagged Invalid;
    tail[1] <= tagged Invalid;
  endmethod
endmodule

module mkMergeTreeWithLastPipeline#(Bool pipelineLast) (MergeTree#(n, t))
  provisos (Bits#(t, tSz));
  Reg#(Bool) cur <- mkReg(True);
  Vector#(n, Reg#(Bool)) epochs <- replicateM(mkReg(True));
  Vector#(n, FIFOF#(t)) iports;
  for (Integer i = 0; i < valueOf(n); i = i + 1) begin
    if (pipelineLast && i == valueOf(n) - 1)
      iports[i] <- mkCRegPipelineFIFOF;
    else
      iports[i] <- mkUGFIFOF;
  end
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

module mkMergeTree(MergeTree#(n, t)) provisos (Bits#(t, tSz));
  let t <- mkMergeTreeWithLastPipeline(False);
  return t;
endmodule
