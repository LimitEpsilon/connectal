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
  Vector#(n, FIFOF#(t)) iports <- replicateM(mkUGFIFOF);
  Vector#(n, Put#(t)) inner;
  Vector#(n, Bool) valid;

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    valid[i] = iports[i].notEmpty;

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    inner[i] =
      interface Put;
        method Action put(x) if (noClear && iports[i].notFull);
          iports[i].enq(x);
        endmethod
      endinterface;

  let idx = findIndex(id, valid);

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    for (Integer i = 0; i < valueOf(n); i = i + 1)
      iports[i].clear;
    noClear <= True;
  endrule

  interface iport = inner;
  method Action deq if (noClear && isValid(idx));
    let i = fromMaybe(?, idx);
    iports[i].deq;
  endmethod
  method first if (isValid(idx)) = iports[fromMaybe(?, idx)].first;
  method notEmpty = isValid(idx);
  method Action clear if (noClear); noClear <= False; endmethod
endmodule

