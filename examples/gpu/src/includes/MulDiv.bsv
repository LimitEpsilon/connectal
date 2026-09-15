import Fifo::*;
import FIFOF::*;
import Vector::*;
import Count::*;

typedef 16 MulWidth;
typedef TAdd#(MulWidth, MulWidth) AddWidth;

// Fused Multiply-Add (FMA)
interface UnsafeFMA;
  (* always_ready *)
  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c);
  (* always_ready *)
  method UInt#(TAdd#(1, AddWidth)) first;
endinterface

// fixed latency of two cycles
(* synthesize *)
module mkUnsafeFMA (UnsafeFMA);
  Reg#(UInt#(MulWidth)) a_r <- mkReg(0);
  Reg#(UInt#(MulWidth)) b_r <- mkReg(0);
  Reg#(UInt#(AddWidth)) c_r <- mkReg(0);
  Reg#(UInt#(TAdd#(1, AddWidth))) p_r <- mkReg(0);

  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c);
    a_r <= a;
    b_r <= b;
    c_r <= c;
    UInt#(TAdd#(1, AddWidth)) p = extend(unsignedMul(a_r, b_r));
    p_r <= p + extend(c_r);
  endmethod

  method first = p_r;
endmodule

typedef struct {
  UInt#(MulWidth) a;
  UInt#(MulWidth) b;
  UInt#(AddWidth) c;
} FMAReq deriving (Bits, Eq, FShow);

interface FMA#(numeric type n);
  method Action enq(UInt#(n) a, UInt#(n) b, UInt#(TAdd#(n, n)) c);
  method UInt#(TAdd#(1, TAdd#(n, n))) first;
  method Action deq;
endinterface

(* synthesize *)
module mkBaseFMA (FMA#(MulWidth));
  let m <- mkUnsafeFMA;
  let computed <- mkReg(False);
  let latched <- mkReg(False);
  RWire#(void) deqReq <- mkRWire;
  RWire#(FMAReq) enqReq <- mkRWire;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    if (enqReq.wget matches tagged Valid .req) begin
      match FMAReq {a: .a, b: .b, c: .c} = req;
      m.enq(a, b, c);
      computed <= latched;
      latched <= True;
    end else if (isValid(deqReq.wget) || !computed) begin
      m.enq(?, ?, ?);
      computed <= latched;
      latched <= False;
    end
  endrule

  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c) if (isValid(deqReq.wget) || !computed);
    enqReq.wset(FMAReq {a: a, b: b, c: c});
  endmethod

  method UInt#(TAdd#(1, AddWidth)) first = m.first;

  method Action deq if (computed);
    deqReq.wset(?);
  endmethod

endmodule

// Fused Multiply-Add Typeclass
typeclass UnsignedFMA#(numeric type n);
  module mkUnsignedFMA (FMA#(n));
endtypeclass

instance UnsignedFMA#(MulWidth);
  module mkUnsignedFMA (FMA#(MulWidth));
    let m <- mkBaseFMA;
    return m;
  endmodule
endinstance

instance UnsignedFMA#(n) provisos (
  Add#(4, lgn, TLog#(hn)), Mul#(2, lgn, l), Div#(n, 2, hn), Add#(hn, hn, n), UnsignedFMA#(hn)
);

  module mkUnsignedFMA (FMA#(n));
    let vn = valueOf(n);
    let vhn = valueOf(hn);

    FMA#(hn) mulUpper <- mkUnsignedFMA;
    FMA#(hn) mulMiddle <- mkUnsignedFMA;
    FMA#(hn) mulLower <- mkUnsignedFMA;

    FIFOF#(Tuple2#(Bit#(TAdd#(1, hn)), Bit#(TAdd#(1, hn)))) midArgs <- mkLFIFOF;
    Fifo#(TAdd#(2, l), Bit#(TAdd#(1, n))) midZ <- mkLatencyFifo(True, True);
    Fifo#(TAdd#(2, l), Bool) midNeg <- mkLatencyFifo(True, True);
    FIFOF#(Bit#(TAdd#(1, n))) midAdj <- mkLFIFOF;

    FIFOF#(Bit#(TAdd#(1, n))) upperRes <- mkLFIFOF;
    FIFOF#(Bit#(hn)) lowerRes <- mkLFIFOF;

    FIFOF#(UInt#(TAdd#(1, TAdd#(n, n)))) res <- mkFIFOF;

    // t = 1
    (* fire_when_enabled *)
    rule mult_middle;
      match {.midx, .midy} = midArgs.first;
      let xNeg = msb(midx);
      let yNeg = msb(midy);
      Bit#(hn) midx_val = truncate(midx);
      Bit#(hn) midy_val = truncate(midy);
      Bit#(hn) adj = -((pack(replicate(yNeg)) & midx_val) + (pack(replicate(xNeg)) & midy_val));
      Bool neg = (xNeg != yNeg) && (midx != 0) && (midy != 0);

      mulMiddle.enq(unpack(midx_val), unpack(midy_val), unpack({adj, 0}));
      midNeg.enq(neg);

      midArgs.deq;
    endrule

    // t = latency(FMA#(hn))
    (* fire_when_enabled *)
    rule process_upper_lower;
      let high = pack(mulUpper.first);
      let midz = midZ.first;
      let low = pack(mulLower.first);

      upperRes.enq(high);
      midAdj.enq(high + low + (low >> vhn) + midz);
      lowerRes.enq(low[vhn-1 : 0]);

      mulUpper.deq;
      midZ.deq;
      mulLower.deq;
    endrule

    // t = latency(FMA#(hn)) + 1
    (* fire_when_enabled *)
    rule compute_middle;
      let low = lowerRes.first;
      let high = upperRes.first;
      let neg = midNeg.first;
      let adj = midAdj.first;
      Bit#(TAdd#(1, n)) mid = {pack(neg), pack(mulMiddle.first)[vn-1 : 0]};

      mid = mid + adj;
      high = high + (mid >> vhn);
      res.enq(unpack({high, mid[vhn-1 : 0], low}));

      lowerRes.deq;
      upperRes.deq;
      midNeg.deq;
      midAdj.deq;
      mulMiddle.deq;
    endrule

    // t = 0
    method Action enq(UInt#(n) x, UInt#(n) y, UInt#(TAdd#(n, n)) z);
      Bit#(hn) x1 = pack(x)[vn-1 : vhn];
      Bit#(hn) x2 = pack(x)[vhn-1 : 0];
      Bit#(hn) y1 = pack(y)[vn-1 : vhn];
      Bit#(hn) y2 = pack(y)[vhn-1 : 0];
      Bit#(hn) z1 = pack(z)[2*vn-1 : vn+vhn];
      Bit#(n) z2 = pack(z)[vn+vhn-1 : vhn];
      Bit#(hn) z3 = pack(z)[vhn-1 : 0];

      Bit#(TAdd#(1, hn)) midx = zeroExtend(x2) - zeroExtend(x1);
      Bit#(TAdd#(1, hn)) midy = zeroExtend(y1) - zeroExtend(y2);

      mulUpper.enq(unpack(x1), unpack(y1), unpack({z1, 0}));
      midArgs.enq(tuple2(midx, midy));
      midZ.enq(zeroExtend(z2) - zeroExtend({z1, z3}));
      mulLower.enq(unpack(x2), unpack(y2), unpack({0, z3}));
    endmethod

    // t = latency(FMA#(hn)) + 2
    method first = res.first;
    method Action deq; res.deq; endmethod
  endmodule
endinstance

interface Multiplier#(numeric type n);
  method Action enq(Bool x_is_signed, Bit#(n) x, Bool y_is_signed, Bit#(n) y);
  method Bit#(TAdd#(n, n)) first;
  method Action deq;
endinterface

module mkMultiplier (Multiplier#(n)) provisos (UnsignedFMA#(n));
  FMA#(n) fma <- mkUnsignedFMA;

  method Action enq(Bool x_is_signed, Bit#(n) x, Bool y_is_signed, Bit#(n) y);
    let xNeg = pack(x_is_signed) & msb(x);
    let yNeg = pack(y_is_signed) & msb(y);
    let adj = -((pack(replicate(yNeg)) & x) + (pack(replicate(xNeg)) & y));

    fma.enq(unpack(x), unpack(y), unpack({adj, 0}));
  endmethod

  method first = truncate(pack(fma.first));
  method Action deq = fma.deq;
endmodule

(* synthesize *)
module mkMul32 (Multiplier#(32));
/*
  Fifo#(4, UInt#(64)) fma <- mkLatencyFifo(True, True); // try out register retiming

  method Action enq(Bool x_is_signed, Bit#(32) x, Bool y_is_signed, Bit#(32) y);
    let xNeg = pack(x_is_signed) & msb(x);
    let yNeg = pack(y_is_signed) & msb(y);
    let adj = -((pack(replicate(yNeg)) & x) + (pack(replicate(xNeg)) & y));

    fma.enq(unsignedMul(unpack(x), unpack(y)) + unpack({adj, 0}));
  endmethod

  method first = pack(fma.first);
  method Action deq = fma.deq;
*/
  Multiplier#(32) m <- mkMultiplier;
  return m;
endmodule

interface Divider#(numeric type n);
  method Action enq(Bool num_is_signed, Bit#(n) num, Bool den_is_signed, Bit#(n) den);
  method Tuple2#(Bit#(n), Bit#(n)) first;
  method Action deq;
endinterface

typedef struct {
  Bool done;
  Bool qneg;
  Bool rneg;
  UInt#(TLog#(n)) dExp;
  Bit#(n) quot; // quotient
  Bit#(n) den;  // denominator
  Bit#(n) rem;  // remainder
} DivRes#(numeric type n) deriving (Bits, Eq, FShow);

// The divider's original critical path ran from countMSB(rem), through the
// shift-amount subtraction and barrel shifters, into the remainder subtractor.
// Registering the shift amount cuts that path close to its routed midpoint.
typedef struct {
  DivRes#(n) res;
  UInt#(TLog#(n)) shamt;
} DivPreRes#(numeric type n) deriving (Bits, Eq, FShow);

typedef union tagged {
  DivRes#(n) DivPreStage;
  DivPreRes#(n) DivPostStage;
} DivState#(numeric type n) deriving (Bits, Eq, FShow);

typedef function DivPreRes#(n) d(DivRes#(n) x) DivStepPre#(numeric type n);
typedef function DivRes#(n) d(DivPreRes#(n) x) DivStepPost#(numeric type n);

function DivPreRes#(n) divStepPre(DivRes#(n) x);
  match DivRes {qneg: .qneg, rneg: .rneg, dExp: .dExp, quot: .quot, den: .den, rem: .rem} = x;
  let rExp = countMSB(rem); // rem = 2 ^ (n - rExp) * 1.xxxx...
  let shamt = dExp - rExp;

  let done = den == 0 || rem < den;
  x.done = done;
  return DivPreRes {res: x, shamt: shamt};
endfunction

function DivRes#(n) divStepPost(DivPreRes#(n) x);
  match DivPreRes {res: .res, shamt: .shamt} = x;
  match DivRes {done: .done, qneg: .qneg, rneg: .rneg, dExp: .dExp,
                quot: .quot, den: .den, rem: .rem} = res;
  Bit#(n) quotShift = 1 << shamt;
  let denShift = den << shamt;

  let quot1 = quot | quotShift;
  let quot2 = quot | (quotShift >> 1);
  let rem1 = rem - denShift;
  let rem2 = rem - (denShift >> 1);
  Bool rem1Neg = unpack(msb(rem1));

  if (!done) quot = rem1Neg ? quot2 : quot1;
  if (!done) rem = rem1Neg ? rem2 : rem1;
  return DivRes {done: done, qneg: qneg, rneg: rneg, dExp: dExp, quot: quot, den: den, rem: rem};
endfunction

typedef 4 DivStage;

module mkDivider#(DivStepPre#(n) stepPre, DivStepPost#(n) stepPost) (Divider#(n));
  Vector#(DivStage, DivStepPre#(n)) divsPre = replicate(stepPre);
  Vector#(DivStage, DivStepPost#(n)) divsPost = replicate(stepPost);
  Vector#(DivStage, Reg#(Maybe#(DivState#(n)))) res <- replicateM(mkReg(tagged Invalid));
  Fifo#(2, Tuple2#(Bit#(n), Bit#(n))) out <- mkCFFifo(False, False);
  RWire#(DivRes#(n)) enqReq <- mkRWire;

  function DivState#(n) genDiv(Integer i);
    case (fromMaybe(?, res[i])) matches
      tagged DivPreStage .r: return tagged DivPostStage divsPre[i](r);
      tagged DivPostStage .r: return tagged DivPreStage divsPost[i](r);
    endcase
  endfunction

  function Bool divDone(Integer i);
    case (fromMaybe(?, res[i])) matches
      tagged DivPreStage .r: return r.done;
      tagged DivPostStage .r: return r.res.done;
    endcase
  endfunction

  function DivRes#(n) divResult(Integer i);
    case (fromMaybe(?, res[i])) matches
      tagged DivPreStage .r: return r;
      // divResult is consumed only when divDone is true. In the post state,
      // that means the pre-stage result was already final, so do not place an
      // unnecessary divStepPost and its subtractors on the output path.
      tagged DivPostStage .r: return r.res;
    endcase
  endfunction

  function Bool genVal(Integer i) = isValid(res[i]);

  Vector#(DivStage, DivState#(n)) stepped = genWith(genDiv);
  Vector#(DivStage, Bool) valid = genWith(genVal);
  Vector#(TAdd#(1, DivStage), Bool) notFull = ?;
  Integer divStage = valueOf(DivStage);
  notFull[divStage] = out.notFull && divDone(divStage-1);
  for (Integer i = divStage - 1; i >= 0; i = i - 1)
    notFull[i] = notFull[i+1] || !valid[i];

  (* fire_when_enabled, no_implicit_conditions *)
  rule shift;
    if (isValid(res[divStage-1])) begin
      let r = divResult(divStage-1);
      match DivRes {done: .done, qneg: .qneg, rneg: .rneg, quot: .quot, rem: .rem} = r;
      if (out.notFull && done) out.enq(tuple2(qneg ? -quot : quot, rneg ? -rem : rem));
    end
    for (Integer i = divStage-1; i > 0; i = i - 1)
      if (notFull[i])
        res[i] <= valid[i-1] ? tagged Valid stepped[i-1] : tagged Invalid;
      else
        res[i] <= valid[i] ? tagged Valid stepped[i] : tagged Invalid;
    if (notFull[0]) begin
      if (enqReq.wget matches tagged Valid .r)
        res[0] <= tagged Valid (tagged DivPreStage r);
      else
        res[0] <= tagged Invalid;
    end else
      res[0] <= valid[0] ? tagged Valid stepped[0] : tagged Invalid;
  endrule

  method Action enq(Bool nsigned, Bit#(n) num, Bool dsigned, Bit#(n) den) if (notFull[0]);
    Bool nneg = nsigned && unpack(msb(num));
    Bool dneg = dsigned && unpack(msb(den));
    let qneg = nneg != dneg;
    let rneg = nneg;
    let rem = nneg ? -num : num;
    let d = dneg ? ~den : den;
    let dExp = countMSB(d); // den = 2 ^ (n - dExp) * 1.xxxx...
    let dPow2 = dneg && (((-1) >> dExp) == d); // checks if d = -2ᵐ for some m
    dExp = dExp - (dPow2 ? 1 : 0);
    let den1 = d + (dneg ? 1 : 0);
    let req = DivRes {done: False, qneg: qneg, rneg: rneg, dExp: dExp, quot: 0, den: den1, rem: rem};
    enqReq.wset(req);
  endmethod

  method first if (out.notEmpty) = out.first;
  method deq if (out.notEmpty) = out.deq;
endmodule

(* noinline *)
function DivPreRes#(32) divStepPre32(DivRes#(32) x) = divStepPre(x);

(* noinline *)
function DivRes#(32) divStepPost32(DivPreRes#(32) x) = divStepPost(x);

(* synthesize *)
module mkDiv32 (Divider#(32));
  Divider#(32) d <- mkDivider(divStepPre32, divStepPost32);
  return d;
endmodule

