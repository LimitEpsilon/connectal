// Adapted from https://github.com/mtikekar/advanced_bsv
import Vector :: *;
import GetPut :: *;

typedef struct {
  Bool epoch;
  Bool valid;
} Epoch deriving(Bits, Eq, FShow);

interface MergeTree#(numeric type n, type t);
  interface Vector#(n, Put#(t)) iport;
  method Action deq;
  method t first;
  method Bool notEmpty;
endinterface

module mkMergeTree(MergeTree#(n, t)) provisos (Bits#(t, tSz));
  (* hide *) Reg#(Maybe#(t)) out[2] <- mkCReg(2, tagged Invalid);
  (* hide *) Vector#(n, Reg#(t)) ibuf <- replicateM(mkRegU);
  (* hide *) Reg#(Bool) cur[2] <- mkCReg(2, False); // current epoch
  Vector#(n, Array#(Reg#(Epoch))) iports;
  Vector#(n, Put#(t)) inner;
  Vector#(n, Bool) epochF;
  Vector#(n, Bool) epochT;

  for (Integer i = 0; i < valueOf(n); i = i + 1)
    iports[i] <- mkCReg(2, Epoch {epoch: False, valid: False});

  for (Integer i = 0; i < valueOf(n); i = i + 1) begin
    match Epoch {epoch: .epoch, valid: .valid} = iports[i][0];
    epochF[i] = epoch ? False : valid;
  end

  for (Integer i = 0; i < valueOf(n); i = i + 1) begin
    match Epoch {epoch: .epoch, valid: .valid} = iports[i][0];
    epochT[i] = epoch ? valid : False;
  end

  for (Integer i = 0; i < valueOf(n); i = i + 1)
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
  method Action deq if (isValid(out[1]));
    out[1] <= tagged Invalid;
  endmethod
  method first if (isValid(out[1])) = fromMaybe(?, out[1]);
  method notEmpty = isValid(out[1]);
endmodule

