import Fifo::*;
import Vector::*;

typedef 17 MulWidth;
typedef TMul#(2, MulWidth) AddWidth;

// Fused Multiply-Add (FMA)
interface UnsafeFMA;
  (* always_ready *)
  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c, Bool sub);
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

  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c, Bool sub);
    a_r <= a;
    b_r <= b;
    c_r <= c;
    UInt#(TAdd#(1, AddWidth)) p = extend(unsignedMul(a_r, b_r));
    p_r <= sub ? p - extend(c_r) : p + extend(c_r);
  endmethod

  method first = p_r;
endmodule

typedef struct {
  UInt#(MulWidth) a;
  UInt#(MulWidth) b;
  UInt#(AddWidth) c;
  Bool sub;
} FMAReq deriving (Bits, Eq, FShow);

interface FMA;
  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c, Bool sub);
  method UInt#(TAdd#(1, AddWidth)) first; // unguarded
  method Action deq;
endinterface

(* synthesize *)
module mkFMA (FMA);
  let m <- mkUnsafeFMA;
  let computed <- mkReg(False);
  let latched <- mkReg(False);
  RWire#(void) deqReq <- mkRWire;
  RWire#(FMAReq) enqReq <- mkRWire;

  (* fire_when_enabled, no_implicit_conditions *)
  rule canonicalize;
    if (enqReq.wget matches tagged Valid .req) begin
      match FMAReq {a: .a, b: .b, c: .c, sub: .sub} = req;
      m.enq(a, b, c, sub);
      computed <= latched;
      latched <= True;
    end else if (isValid(deqReq.wget) || !computed) begin
      m.enq(?, ?, ?, ?);
      computed <= latched;
      latched <= False;
    end
  endrule

  method Action enq(UInt#(MulWidth) a, UInt#(MulWidth) b, UInt#(AddWidth) c, Bool sub) if (isValid(deqReq.wget) || !computed);
    enqReq.wset(FMAReq {a: a, b: b, c: c, sub: sub});
  endmethod

  method UInt#(TAdd#(1, AddWidth)) first = m.first;

  method Action deq if (computed);
    deqReq.wset(?);
  endmethod
endmodule

interface Mul32;
  method Action enq(Bool x_is_signed, Bit#(32) x, Bool y_is_signed, Bit#(32) y);
  method Bit#(64) first;
  method Action deq;
endinterface

// latency 5
(* synthesize *)
module mkMul32 (Mul32);
  let mulUpper <- mkFMA;
  let mulMiddle <- mkFMA;
  let mulLower <- mkFMA;
  Fifo#(1, Tuple2#(Bit#(32), Bit#(32))) uxy <- mkPipelineFifo(True, True);
  Fifo#(1, Tuple2#(UInt#(MulWidth), UInt#(MulWidth))) middleArgs <- mkPipelineFifo(True, True);
  Fifo#(2, Bit#(32)) upperRes <- mkLatencyFifo(True, True);
  Fifo#(2, Bit#(32)) lowerRes <- mkLatencyFifo(True, True);
  Fifo#(4, Bool) resNeg <- mkLatencyFifo(True, True);
  Fifo#(2, Bit#(64)) res <- mkCFFifo(True, True);

  (* fire_when_enabled *)
  rule compute_middle;
    match {.ux, .uy} = uxy.first;
    UInt#(MulWidth) uxUpper = extend(unpack(ux[31:16]));
    UInt#(MulWidth) uxLower = extend(unpack(ux[15:0]));
    UInt#(MulWidth) uyUpper = extend(unpack(uy[31:16]));
    UInt#(MulWidth) uyLower = extend(unpack(uy[15:0]));
    middleArgs.enq(tuple2(uxUpper + uxLower, uyUpper + uyLower));
    uxy.deq;
  endrule

  (* fire_when_enabled *)
  rule multiply_middle;
    Bit#(32) upper = truncate(pack(mulUpper.first));
    Bit#(32) lower = truncate(pack(mulLower.first));
    match {.ux, .uy} = middleArgs.first;

    let lower1 = lower - extend(lower[31:16]);
    UInt#(AddWidth) middleSub = unpack(extend(upper)) + unpack(extend(lower1));

    upperRes.enq(upper);
    mulMiddle.enq(ux, uy, middleSub, True);
    lowerRes.enq(lower);

    mulUpper.deq;
    mulLower.deq;
    middleArgs.deq;
  endrule

  (* fire_when_enabled *)
  rule compute_end;
    let upper = upperRes.first;
    let middle = pack(mulMiddle.first);
    let lower = lowerRes.first;
    let neg = resNeg.first;

    Bit#(32) upper1 = upper + extend(middle[32:16]);
    Bit#(64) abs = {upper1, middle[15:0], lower[15:0]};
    res.enq(neg ? -abs : abs);

    upperRes.deq;
    mulMiddle.deq;
    lowerRes.deq;
    resNeg.deq;
  endrule

  method Action enq(Bool x_is_signed, Bit#(32) x, Bool y_is_signed, Bit#(32) y);
    Bool xNeg = x_is_signed && unpack(msb(x));
    Bool yNeg = y_is_signed && unpack(msb(y));
    Bit#(32) ux = xNeg ? -x : x;
    UInt#(MulWidth) uxUpper = extend(unpack(ux[31:16]));
    UInt#(MulWidth) uxLower = extend(unpack(ux[15:0]));
    Bit#(32) uy = yNeg ? -y : y;
    UInt#(MulWidth) uyUpper = extend(unpack(uy[31:16]));
    UInt#(MulWidth) uyLower = extend(unpack(uy[15:0]));

    mulUpper.enq(uxUpper, uyUpper, 0, False);
    uxy.enq(tuple2(ux, uy));
    mulLower.enq(uxLower, uyLower, 0, False);
    resNeg.enq(xNeg != yNeg);
  endmethod

  method first = res.first;
  method Action deq; res.deq; endmethod
endmodule

interface Div32;
  method Action enq(Bool num_is_signed, Bit#(32) num, Bool den_is_signed, Bit#(32) den);
  method Tuple2#(Bit#(32), Bit#(32)) first;
  method Action deq;
endinterface

typedef struct {
  Bool done;
  Bool qneg;
  Bool rneg;
  Bit#(32) quot; // quotient
  Bit#(32) den;  // denominator
  Bit#(32) rem;  // remainder
} DivRes deriving (Bits, Eq, FShow);

typedef function DivRes d(DivRes x) DivStep;

(* noinline *)
function DivRes divStep(DivRes x);
  match DivRes {qneg: .qneg, rneg: .rneg, quot: .quot, den: .den, rem: .rem} = x;
  Vector#(32, Bool) r = reverse(unpack(rem));
  let rExp = fromMaybe(?, findIndex(id, r)); // rem = 2 ^ (32 - rExp) * 1.xxxx...
  Vector#(32, Bool) d = reverse(unpack(den));
  let dExp = fromMaybe(?, findIndex(id, d)); // den = 2 ^ (32 - dExp) * 1.xxxx...
  let shamt = dExp - rExp;
  let quotShift = 32'b1 << shamt;
  let denShift = den << shamt;

  let quot1 = quot | quotShift;
  let quot2 = quot | {1'b0, quotShift[31:1]};
  let rem1 = rem - denShift;
  let rem2 = rem - {1'b0, denShift[31:1]};
  Bool rem1Neg = unpack(rem1[31]);

  let done = den == 0 || rem < den;
  if (!done) quot = rem1Neg ? quot2 : quot1;
  if (!done) rem = rem1Neg ? rem2 : rem1;
  return DivRes {done: done, qneg: qneg, rneg: rneg, quot: quot, den: den, rem: rem};
endfunction

typedef 4 DivStage;

(* synthesize *)
module mkDiv32 (Div32);
  Vector#(DivStage, DivStep) divs = replicate(divStep);
  Vector#(DivStage, Reg#(Maybe#(DivRes))) res <- replicateM(mkReg(tagged Invalid));
  Fifo#(2, Tuple2#(Bit#(32), Bit#(32))) out <- mkCFFifo(False, False);
  RWire#(DivRes) enqReq <- mkRWire;

  function DivRes genDiv(Integer i) = divs[i](fromMaybe(?, res[i]));
  function Bool genVal(Integer i) = isValid(res[i]);

  Vector#(DivStage, DivRes) stepped = genWith(genDiv);
  Vector#(DivStage, Bool) valid = genWith(genVal);
  Vector#(TAdd#(1, DivStage), Bool) notFull = ?;
  Integer divStage = valueOf(DivStage);
  notFull[divStage] = out.notFull && fromMaybe(?, res[divStage-1]).done;
  for (Integer i = divStage - 1; i >= 0; i = i - 1)
    notFull[i] = notFull[i+1] || !valid[i];

  (* fire_when_enabled, no_implicit_conditions *)
  rule shift;
    if (res[divStage-1] matches tagged Valid .r) begin
      match DivRes {done: .done, qneg: .qneg, rneg: .rneg, quot: .quot, rem: .rem} = r;
      if (out.notFull && done) out.enq(tuple2(qneg ? -quot : quot, rneg ? -rem : rem));
    end
    for (Integer i = divStage-1; i > 0; i = i - 1)
      if (notFull[i])
        res[i] <= valid[i-1] ? tagged Valid stepped[i-1] : tagged Invalid;
      else
        res[i] <= valid[i] ? tagged Valid stepped[i] : tagged Invalid;
    if (notFull[0])
      res[0] <= enqReq.wget;
    else
      res[0] <= valid[0] ? tagged Valid stepped[0] : tagged Invalid;
  endrule

  method Action enq(Bool nsigned, Bit#(32) num, Bool dsigned, Bit#(32) den) if (notFull[0]);
    Bool nneg = nsigned && unpack(msb(num));
    Bool dneg = dsigned && unpack(msb(den));
    let qneg = nneg != dneg;
    let rneg = nneg;
    let rem = nneg ? -num : num;
    let den1 = dneg ? -den : den;
    let req = DivRes {done: False, qneg: qneg, rneg: rneg, quot: 0, den: den1, rem: rem};
    enqReq.wset(req);
  endmethod

  method first if (out.notEmpty) = out.first;
  method deq if (out.notEmpty) = out.deq;
endmodule

