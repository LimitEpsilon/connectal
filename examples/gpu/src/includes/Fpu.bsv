// Fpu.bsv
// Single-precision vector floating-point unit built from the Berkeley
// HardFloat modules in includes/hardfloat.
//
// Operands are recoded once, in mkVectorFpu's dispatch rule, and results are
// unrecoded once, in its finish rule; every datapath in between carries the
// 33-bit recoded form.  RawFloat is decoded where a datapath wants it rather
// than carried between stages, since it is six bits wider and the decode is
// a handful of gates.
//
// Three datapaths are replicated per thread: mkFloatMulAdd for the
// arithmetic ops, mkFloatDivSqrt for FDiv and FSqrt, and mkFloatSimple for
// everything else.  mkVectorFpu records the issue order in a FIFO and
// collects from the matching one, so the three may have different latencies
// without results going out of order.

import Types::*;
import ProcTypes::*;
import Vector::*;
import Fifo::*;
import FIFOF::*;
import ClientServer::*;
import GetPut::*;
import FloatingPoint::*;
import HardFloat::*;
import MulAddRecFN::*;
import DivSqrtRecFN::*;

typedef  8 FpExpW;
typedef 24 FpSigW;
typedef TAdd#(1, TAdd#(FpExpW, FpSigW)) RecFpW;

Bit#(32) f32_one = 32'h3F800000;

// The RISC-V canonical NaN (0x7FC00000) recoded: sign 0, the three-bit
// special code 111 marking a NaN, and a payload whose leading bit is set so
// the NaN is quiet.
Bit#(RecFpW) recF32_canonicalNaN = {1'b0, 9'b111000000, 1'b1, 22'b0};

typedef struct {
  Bit#(32) data;
  Bit#(5)  fflags;
} FpuResult deriving(Bits, Eq, FShow);

// A datapath result: either a recoded float or, for the ops that produce an
// integer, a 32-bit value in the low bits.  Which one is decided from the
// opcode in finish.
typedef struct {
  Bit#(RecFpW) data;
  Bit#(5)      fflags;
} FpuRecResult deriving(Bits, Eq, FShow);

////////////////////////////////////////////////////////////////////////////
// Fused multiply-add
////////////////////////////////////////////////////////////////////////////

typedef struct {
  Bit#(2)      op;
  Bit#(3)      rm;
  Bit#(RecFpW) a;
  Bit#(RecFpW) b;
  Bit#(RecFpW) c;
} MulAddArg deriving (Bits, Eq, FShow);

typedef struct {
  Bit#(3)                        rm;
  Bit#(FpSigW)                   mulA;
  Bit#(FpSigW)                   mulB;
  Bit#(TAdd#(FpSigW, FpSigW))    mulC;
  MulAddInterIo#(FpExpW, FpSigW) inter;
} MulAddPre deriving (Bits, Eq);

typedef struct {
  Bit#(3)                               rm;
  Bit#(TAdd#(TAdd#(FpSigW, FpSigW), 1)) prod;
  MulAddInterIo#(FpExpW, FpSigW)        inter;
} MulAddProd deriving (Bits, Eq);

// op[1] negates the product and op[0] negates the addend, so a*b+c, a*b-c,
// -(a*b)+c and -(a*b)-c are one encoding apart.  The boundary between premul
// and postmul is the one the reference Verilog leaves between
// mulAddRecFNToRaw_preMul and mulAddRecFNToRaw_postMul.
(* synthesize *)
module mkFloatMulAdd(Server#(MulAddArg, FpuRecResult));
  FIFOF#(MulAddArg)    argQ  <- mkFIFOF;
  FIFOF#(MulAddPre)    preQ  <- mkFIFOF;
  FIFOF#(MulAddProd)   prodQ <- mkFIFOF;
  FIFOF#(FpuRecResult) outQ  <- mkFIFOF;

  RoundRawFNToRecFN#(FpExpW, FpSigW) roundRawToRecF32 = mkRoundRawFNToRecFN(0);

  (* fire_when_enabled *)
  rule premul;
    let x <- toGet(argQ).get;
    RawFloat#(FpExpW, FpSigW) rawA = rawFloatFromRecFN(x.a);
    RawFloat#(FpExpW, FpSigW) rawB = rawFloatFromRecFN(x.b);
    RawFloat#(FpExpW, FpSigW) rawC = rawFloatFromRecFN(x.c);
    match {.mulA, .mulB, .mulC, .inter} =
      mulAddRawFN_preMul(x.op, rawA, rawB, rawC);
    preQ.enq(MulAddPre {
      rm: x.rm, mulA: mulA, mulB: mulB, mulC: mulC, inter: inter
    });
  endrule

  (* fire_when_enabled *)
  rule multiply;
    let x <- toGet(preQ).get;
    Bit#(TAdd#(FpSigW, FpSigW)) mulProd =
      zeroExtend(x.mulA) * zeroExtend(x.mulB);
    Bit#(TAdd#(TAdd#(FpSigW, FpSigW), 1)) mulAddResult =
      zeroExtend(mulProd) + zeroExtend(x.mulC);
    prodQ.enq(MulAddProd { rm: x.rm, prod: mulAddResult, inter: x.inter });
  endrule

  (* fire_when_enabled *)
  rule postmul;
    let x <- toGet(prodQ).get;
    match {.invalidExc, .rawOut} =
      mulAddRawFN_postMul(x.inter, x.prod, x.rm);
    match {.rec, .exc} =
      roundRawToRecF32(invalidExc, False, rawOut, x.rm, tininess_afterRounding);
    outQ.enq(FpuRecResult { data: rec, fflags: pack(exc) });
  endrule

  interface Put request = toPut(argQ);
  interface Get response = toGet(outQ);
endmodule

////////////////////////////////////////////////////////////////////////////
// Divide and square root
////////////////////////////////////////////////////////////////////////////

typedef struct {
  Bool         sqrtOp;
  Bit#(3)      rm;
  Bit#(RecFpW) a;
  Bit#(RecFpW) b;
} DivSqrtArg deriving (Bits, Eq, FShow);

// A digit recurrence producing one bit of result per cycle, with one
// operation in flight.  The output register is filled the cycle the core
// reports a result and the next operation only starts once it is free, which
// is what keeps that result from being overwritten.
(* synthesize *)
module mkFloatDivSqrt(Server#(DivSqrtArg, FpuRecResult));
  DivSqrtRecFN_small#(FpExpW, FpSigW) core <- mkDivSqrtRecFN_small(0);

  // Unguarded: `req` is always_enabled, so the rule that drives it may not
  // pick up an implicit condition from the argument queue.
  FIFOF#(DivSqrtArg) argQ <- mkUGFIFOF;
  Reg#(Maybe#(FpuRecResult)) outSlot[2] <- mkCReg(2, tagged Invalid);

  (* fire_when_enabled, no_implicit_conditions *)
  rule drive;
    Bool done = core.outValid_div || core.outValid_sqrt;
    Bool start = core.inReady && !done && argQ.notEmpty && !isValid(outSlot[1]);

    let x = argQ.first;
    core.req(start, x.sqrtOp, x.a, x.b, x.rm);
    if (start) argQ.deq;

    if (done) begin
      match {.rec, .exc} = core.result(tininess_afterRounding);
      FpuRecResult res = FpuRecResult { data: rec, fflags: pack(exc) };
      outSlot[1] <= tagged Valid res;
    end
  endrule

  interface Put request;
    method Action put(DivSqrtArg x) if (argQ.notFull);
      argQ.enq(x);
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(FpuRecResult) get if (isValid(outSlot[0]));
      outSlot[0] <= tagged Invalid;
      return fromMaybe(?, outSlot[0]);
    endmethod
  endinterface
endmodule

////////////////////////////////////////////////////////////////////////////
// Comparison, classification, sign injection, moves and integer conversion
////////////////////////////////////////////////////////////////////////////

// iv1 is rs1 before recoding.  The moves have to reproduce their source bit
// for bit and the integer-to-float conversions read an integer, so those
// three take iv1 while everything else works on the recoded operands.
typedef struct {
  FpuFunc      f;
  Bit#(3)      rm;
  Bit#(RecFpW) rv1;
  Bit#(RecFpW) rv2;
  Bit#(32)     iv1;
} SimpleArg deriving (Bits, Eq, FShow);

(* noinline *)
function FpuRecResult execFloatSimple(FpuFunc fpu_f, Bit#(3) fpu_rm, Bit#(RecFpW) rv1, Bit#(RecFpW) rv2, Bit#(32) iv1);
    CompareRecFN#(FpExpW, FpSigW) compareRecF32 = mkCompareRecFN;
    ClassifyRecFN#(FpExpW, FpSigW) classifyRecF32 = classifyRecFN;
    function INToRecFN#(32, FpExpW, FpSigW) iN32ToRecF32(Bool signedOp) = mkINToRecFN(signedOp);
    function RecFNToIN#(FpExpW, FpSigW, 32) recF32ToIN32(Bool signedOp) = mkRecFNToIN(signedOp);

    Bit#(RecFpW) dst = ?;
    Exception e = unpack(0);

    RawFloat#(FpExpW, FpSigW) raw1 = rawFloatFromRecFN(rv1);
    RawFloat#(FpExpW, FpSigW) raw2 = rawFloatFromRecFN(rv2);

    match CompareRes {lt: .lt, eq: .eq, gt: .gt, fflags: Exception {invalid_op: .cmp_invalid}} = compareRecF32(rv1, rv2, False);
    match {.int_res, .int_exc} = recF32ToIN32(fpu_f == FCvt_WF, rv1, fpu_rm);
    match {.float_res, .float_exc} = iN32ToRecF32(fpu_f == FCvt_FW, iv1, fpu_rm, tininess_afterRounding);

    // Fpu Decoding
    case (fpu_f)
        // combinational instructions
        FMin, FMax: begin
            e.invalid_op = cmp_invalid;
            Bool isMax = unpack(pack(fpu_f)[1]);
            // lt and gt are already false when either operand is a NaN, so
            // the NaN term below does not overlap the ordinary one.
            Bool sel = isMax ? lt : gt;
            // Zeros compare equal, so pick by sign to keep min(-0,+0) = -0
            // and max(-0,+0) = +0.
            Bool zsel = isMax ? (raw1.sign && !raw2.sign) : (raw2.sign && !raw1.sign);
            Bool pickRv2 = (raw1.isNaN && !raw2.isNaN) || sel || (eq && zsel);
            dst = (raw1.isNaN && raw2.isNaN) ? recF32_canonicalNaN
                                             : (pickRv2 ? rv2 : rv1);
        end
        FEq, FLt, FLe: begin
            // FEq is quiet; FLt and FLe signal on any NaN.
            e.invalid_op = cmp_invalid ||
              ((fpu_f != FEq) && (raw1.isNaN || raw2.isNaN));
            dst = zeroExtend(~pack(fpu_f)[0] & pack(eq) | ~pack(fpu_f)[1] & pack(lt));
        end
        // CLASS functions
        FClass: dst = zeroExtend(classifyRecF32(rv1));
        // Sign Injection
        FSgnj, FSgnjn, FSgnjx: begin
            dst = rv1;
            let x =
              unpack(pack(fpu_f)[1]) ? // FSgnjn
              1'b1 :
              pack(fpu_f)[3] & rv1[32]; // fpu_f[3] == 1 → FSgnjx
            dst[32] = x ^ rv2[32];
        end
        // Float → Bits, Bits → Float
        FMv_XF, FMv_FX: dst = zeroExtend(iv1);
        // Float → Int
        FCvt_WF, FCvt_WUF: begin
            dst = zeroExtend(int_res);
            // A result that does not fit is clipped and reported as invalid,
            // not as an overflow.
            e.invalid_op = unpack(int_exc[2] | int_exc[1]);
            e.inexact = unpack(int_exc[0]);
        end
        // Int → Float
        FCvt_FW, FCvt_FWU: begin
            dst = float_res;
            e = float_exc;
        end
    endcase
    return FpuRecResult { data: dst, fflags: pack(e) };
endfunction

(* synthesize *)
module mkFloatSimple (Server#(SimpleArg, FpuRecResult));
  FIFOF#(SimpleArg)    argQ <- mkFIFOF;
  FIFOF#(FpuRecResult) outQ <- mkFIFOF;

  (* fire_when_enabled *)
  rule exec_simple;
    let x <- toGet(argQ).get;
    outQ.enq(execFloatSimple(x.f, x.rm, x.rv1, x.rv2, x.iv1));
  endrule

  interface Put request = toPut(argQ);
  interface Get response = toGet(outQ);
endmodule

////////////////////////////////////////////////////////////////////////////
// Vector wrapper
////////////////////////////////////////////////////////////////////////////

typedef struct {
  FpuFunc f;
  Vector#(n, Bit#(32)) v1;
  Vector#(n, Bit#(32)) v2;
  Vector#(n, Bit#(32)) v3;
} FpuReq#(numeric type n) deriving (Bits, Eq, FShow);

typedef struct {
  FpuFunc                      f;
  RVRoundMode                  rm;
  Vector#(ThreadNum, Bit#(32)) v1;
  Vector#(ThreadNum, Bit#(32)) v2;
  Vector#(ThreadNum, Bit#(32)) v3;
} FpuIssue deriving (Bits, Eq, FShow);

interface VectorFpu;
    method Action       exec(FpuFunc f, RVRoundMode rm, Vector#(ThreadNum, Bit#(32)) rVal1, Vector#(ThreadNum, Bit#(32)) rVal2, Vector#(ThreadNum, Bit#(32)) rVal3);
    method Bool         notEmpty; // True if there is any instruction in this pipeline
    // output
    method Bool                             result_rdy;
    method Vector#(ThreadNum, FpuResult)    result_data;
    method Action                           result_deq;
endinterface

(* synthesize *)
module mkFpuExecFifoOut(Fifo#(8, Vector#(ThreadNum, FpuResult)));
  let m <- mkBRAMFifo(True, True);
  return m;
endmodule

(* synthesize *)
module mkVectorFpu(VectorFpu);
    FIFOF#(FpuIssue) issueQ <- mkFIFOF;
    Fifo#(8, FpuFunc) fpu_func_fifo <- mkCFFifo(True, True); // records issue order
    Fifo#(8, Vector#(ThreadNum, FpuResult)) fpu_exec_fifo_out <- mkFpuExecFifoOut; // all datapaths dequeue into this

    Vector#(ThreadNum, Server#(MulAddArg, FpuRecResult))  float_mulAdd  <- replicateM(mkFloatMulAdd);
    Vector#(ThreadNum, Server#(DivSqrtArg, FpuRecResult)) float_divSqrt <- replicateM(mkFloatDivSqrt);
    Vector#(ThreadNum, Server#(SimpleArg, FpuRecResult))  float_simple  <- replicateM(mkFloatSimple);

    RecFNFromFN#(FpExpW, FpSigW) f32ToRecF32 = recFNFromFN;
    FNFromRecFN#(FpExpW, FpSigW) recF32ToF32 = fNFromRecFN;

    rule dispatch;
        let x <- toGet(issueQ).get;

        Bit#(3) fpu_rm = case (x.rm)
            RNE:     round_near_even;
            RTZ:     round_minMag;
            RDN:     round_min;
            RUP:     round_max;
            RMM:     round_near_maxMag;
            default: round_near_even;
        endcase;

        // op[1] negates the product, op[0] negates the addend.
        Bit#(2) fmaOp = case (x.f)
            FSub:    2'b01;
            FMSub:   2'b01;
            FNMSub:  2'b10;
            FNMAdd:  2'b11;
            default: 2'b00; // FAdd, FMul, FMAdd
        endcase;
        Bool isAddSub = (x.f == FAdd) || (x.f == FSub);
        Bool isMul = (x.f == FMul);

        // single precision
        // Fpu Decoding
        for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1) begin
            // An add is 1.0*v1 (+/-) v2 and a multiply is v1*v2 plus a zero
            // carrying the product's sign, which is what makes the sign of a
            // zero product come out right.  Everything else leaves the three
            // sources alone, so one mux ahead of the recoders covers all of
            // them.
            Bit#(1) prodSign = x.v1[i][31] ^ x.v2[i][31];
            Bit#(32) src1 = isAddSub ? f32_one : x.v1[i];
            Bit#(32) src2 = isAddSub ? x.v1[i] : x.v2[i];
            Bit#(32) src3 = isAddSub ? x.v2[i] :
                            isMul    ? {prodSign, 31'b0} :
                                       x.v3[i];
            Bit#(RecFpW) rec1 = f32ToRecF32(src1);
            Bit#(RecFpW) rec2 = f32ToRecF32(src2);
            Bit#(RecFpW) rec3 = f32ToRecF32(src3);
            case (x.f)
                FAdd, FSub, FMul, FMAdd, FMSub, FNMSub, FNMAdd:
                        float_mulAdd[i].request.put(MulAddArg {
                          op: fmaOp, rm: fpu_rm, a: rec1, b: rec2, c: rec3 });
                FDiv, FSqrt:
                        float_divSqrt[i].request.put(DivSqrtArg {
                          sqrtOp: (x.f == FSqrt), rm: fpu_rm,
                          a: rec1, b: rec2 });
                default: float_simple[i].request.put(SimpleArg {
                          f: x.f, rm: fpu_rm, rv1: rec1, rv2: rec2, iv1: src1 });
            endcase
        end
        fpu_func_fifo.enq(x.f);
    endrule

    rule finish;
        let fpu_f = fpu_func_fifo.first;
        fpu_func_fifo.deq;

        Bool floatOut = case (fpu_f)
            FEq, FLt, FLe, FClass: False;
            FMv_XF, FMv_FX: False;
            FCvt_WF, FCvt_WUF: False;
            default: True;
        endcase;

        Vector#(ThreadNum, FpuResult) exec_out;
        // Fpu Decoding
        for (Integer i = 0; i < valueOf(ThreadNum); i = i + 1) begin
            FpuRecResult out = unpack(0);
            case (fpu_f)
                FAdd, FSub, FMul, FMAdd, FMSub, FNMSub, FNMAdd:
                        begin out <- float_mulAdd[i].response.get; end
                FDiv, FSqrt:
                        begin out <- float_divSqrt[i].response.get; end
                default: begin out <- float_simple[i].response.get; end
            endcase
            Bit#(32) data = floatOut ? recF32ToF32(out.data) : truncate(out.data);
            exec_out[i] = FpuResult { data: zeroExtend(data), fflags: out.fflags };
        end
        fpu_exec_fifo_out.enq(exec_out);
    endrule

    method Action exec(FpuFunc fpu_f, RVRoundMode rm, Vector#(ThreadNum, Bit#(32)) rVal1, Vector#(ThreadNum, Bit#(32)) rVal2, Vector#(ThreadNum, Bit#(32)) rVal3);
        issueQ.enq(FpuIssue { f: fpu_f, rm: rm, v1: rVal1, v2: rVal2, v3: rVal3 });
    endmethod

    method notEmpty = fpu_exec_fifo_out.notEmpty;
    // output
    method result_rdy = fpu_exec_fifo_out.notEmpty;
    method result_data = fpu_exec_fifo_out.first;
    method result_deq = fpu_exec_fifo_out.deq;
endmodule
