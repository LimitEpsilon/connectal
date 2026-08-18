// Adapted from https://github.com/mtikekar/advanced_bsv
import Vector::*;

typedef struct {
  Bit#(k) key;
  t val;
} KV#(numeric type k, type t) deriving (Bits, Eq, FShow);

// coalescing request
typedef Vector#(n, Maybe#(KV#(k, t)))
  CoalReq#(numeric type n, numeric type k, type t);

// coalesced response
typedef struct {
  Bit#(n) mask;
  KV#(k, t) kv;
} CoalResp#(numeric type n, numeric type k, type t) deriving (Bits, Eq);

instance FShow#(CoalResp#(n, k, t)) provisos (FShow#(t));
  function Fmt fshow(CoalResp#(n, k, t) x);
    return $format("{mask: %0b, key: %0h, val: ", x.mask, x.kv.key) + fshow(x.kv.val) + fshow("}");
  endfunction
endinstance

interface CoalTree#(numeric type n, numeric type k, type t);
  method Action enq(CoalReq#(n, k, t) v);
  method Bool notEmpty;
  method Bool getEpoch;
  method Action deq;
  method CoalResp#(n, k, t) first;
endinterface

typeclass Coalescer#(numeric type n, numeric type k, type t);
  module mkCoalTree_#(function t merge(t x, t y)) (CoalTree#(n, k, t));
endtypeclass

instance Coalescer#(1, k, t) provisos (Bits#(t, tSz), FShow#(t));
  // Base instance of 1-long vector
  module mkCoalTree_#(function t merge(t x, t y)) (CoalTree#(1, k, t));
    Reg#(CoalResp#(1, k, t)) in <- mkReg(CoalResp {mask: 0, kv: unpack(0)});
    Reg#(Bool) rdy[2] <- mkCReg(2, False);
    Reg#(Bool) epoch <- mkReg(True);

    method Action enq(CoalReq#(1, k, t) v) if (!rdy[1]);
      in <= CoalResp {mask: pack(isValid(v[0])), kv: fromMaybe(?, v[0])};
      rdy[1] <= True;
    endmethod

    method notEmpty = rdy[0];

    method getEpoch = epoch;

    method Action deq;
      rdy[0] <= False;
      epoch <= !epoch;
    endmethod // must be called under if (notEmpty)

    method first = in;
  endmodule
endinstance

instance Coalescer#(n, k, t) provisos (
  Div#(n, 2, hn), Add#(hn, hm, n),
  Coalescer#(hn, k, t), Coalescer#(hm, k, t),
  Bits#(t, tSz), FShow#(t)
);

  // General case
  module mkCoalTree_#(function t merge(t x, t y)) (CoalTree#(n, k, t));
    // two subtrees
    CoalTree#(hn, k, t) l <- mkCoalTree_(merge);
    CoalTree#(hm, k, t) r <- mkCoalTree_(merge);
    Reg#(CoalResp#(n, k, t)) out <- mkReg(CoalResp {mask: 0, kv: unpack(0)});
    Reg#(Bool) rdy[3] <- mkCReg(3, False);
    Reg#(Bool) epoch[2] <- mkCReg(2, False);

    (* fire_when_enabled, no_implicit_conditions *)
    rule get_result(!rdy[1]);
      let rdyL = l.notEmpty;
      let rdyR = r.notEmpty;
      let e = epoch[0];
      let epochL = l.getEpoch;
      let epochR = r.getEpoch;
      let respL = l.first;
      let respR = r.first;

      CoalResp#(n, k, t) selL = CoalResp {
        mask: {0, respL.mask},
        kv: respL.kv
      }; // select left

      CoalResp#(n, k, t) selR = CoalResp {
        mask: {respR.mask, 0},
        kv: respR.kv
      }; // select right

      CoalResp#(n, k, t) selB = CoalResp {
        mask: {respR.mask, respL.mask},
        kv: KV {key: respL.kv.key, val: merge(respL.kv.val, respR.kv.val)}
      }; // select both

      let dir = compare(respL.kv.key, respR.kv.key);
      let sel = case (dir) LT: selL; GT: selR; EQ: selB; endcase;

      if (rdyL) begin
        if (rdyR) begin
          if (epochL == epochR) begin // update epoch
            epoch[0] <= epochL;
            if (respL.mask != 0 && respR.mask != 0) begin
              out <= sel;
              if (dir != GT) l.deq;
              if (dir != LT) r.deq;
            end else begin
              out <= respL.mask == 0 ? selR : selL;
              l.deq; r.deq;
            end
          end else if (e == epochL) begin // reqL cannot be empty
            out <= selL;
            l.deq;
          end else begin // e == epochR
            out <= selR;
            r.deq;
          end
        end else if (e == epochL) begin
          out <= selL;
          l.deq;
        end
      end else if (rdyR && e == epochR) begin
        out <= selR;
        r.deq;
      end
      rdy[1] <= rdyL && (rdyR || e == epochL) || rdyR && e == epochR;
    endrule

    method Action enq(CoalReq#(n, k, t) v);
      l.enq(take(v));
      r.enq(takeTail(v));
    endmethod

    method notEmpty = rdy[0];

    // method getEpoch = (empty[0] && epoch != epochL) ? epochR : epoch;
    method getEpoch = epoch[0];

    method Action deq; rdy[0] <= False; endmethod // must be called under if (notEmpty)

    method first = out;
  endmodule
endinstance

// guard deq and first only at the interface
module mkCoalTree#(function t merge (t x, t y)) (CoalTree#(n, k, t))
  provisos (Coalescer#(n, k, t));
  (* hide *) CoalTree#(n, k, t) inner <- mkCoalTree_(merge);

  method enq = inner.enq;
  method notEmpty = inner.notEmpty;
  method getEpoch = inner.getEpoch;
  method deq if (inner.notEmpty) = inner.deq;
  method first if (inner.notEmpty) = inner.first;
endmodule

