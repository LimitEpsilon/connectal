import Vector::*;
import FloatingPoint::*;
import HardFloat::*;

// Mirrors HardFloat Chisel: DivSqrtRawFN_small (see hardfloat
// DivSqrtRecFN_small.scala). Unlike Add/Mul/MulAdd, this is a genuine
// multi-cycle sequential module (a non-restoring digit-recurrence divider/
// square-rooter), not a pure combinational function: one bit (or two, with
// the divSqrtOpt_twoBitsPerCycle option) of the result is produced per
// clock cycle.
//
// Wherever the Chisel source ORs together several `Mux(cond, value, 0)`
// terms into one register's next value, this port keeps that same literal
// OR-of-masked-terms structure instead of trying to prove the conditions
// mutually exclusive and rewrite it as if/else — several of these terms
// (notably sigX_Z and notZeroRem_Z) are genuinely a sticky/bit-accumulate
// pattern, not a one-of-N select, so collapsing them by hand would be a
// correctness risk for no real readability gain.
interface DivSqrtRawFN_small#(numeric type expWidth, numeric type sigWidth);
  (* always_ready *)
  method Bool inReady;
  (* always_ready, always_enabled *)
  method Action req(
    Bool inValid,
    Bool sqrtOp,
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b,
    Bit#(3) roundingMode
  );
  (* always_ready *)
  method Bool rawOutValid_div;
  (* always_ready *)
  method Bool rawOutValid_sqrt;
  (* always_ready *)
  method Bit#(3) roundingModeOut;
  (* always_ready *)
  method Bool invalidExc;
  (* always_ready *)
  method Bool infiniteExc;
  (* always_ready *)
  method RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
endinterface

module mkDivSqrtRawFN_small#(Bit#(5) options)(DivSqrtRawFN_small#(expWidth, sigWidth))
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );
  Integer sW = valueOf(sigWidth);
  Integer eW = valueOf(expWidth);

  // inReady/rawOutValid are NOT separate registers (the Chisel source's
  // "val inReady = RegInit(true.B)" / "val rawOutValid = RegInit(false.B)"
  // are updated by the exact same computeCycleNum closure as cycleNum
  // itself, on the exact same enable condition, so the invariants
  // inReady == (cycleNum <= 1) and rawOutValid == (cycleNum == 1) hold at
  // all times by induction — true initially (cycleNum=0), and preserved
  // by every update). We derive them combinationally from cycleNum
  // instead, exactly as Chisel's own FIRRTL optimizer does (confirmed in
  // the reference divSqrtRecFN_small.v: "assign inReady = (cycleNum <=
  // 1);"). This also avoids depending on a second/third register's reset
  // value, since cycleNum's own reset to 0 is all that's needed.
  Reg#(Bit#(TLog#(TAdd#(sigWidth, 3)))) cycleNum <- mkReg(0);

  Reg#(Bool) sqrtOp_Z <- mkRegU;
  Reg#(Bool) majorExc_Z <- mkRegU;
  Reg#(Bool) isNaN_Z <- mkRegU;
  Reg#(Bool) isInf_Z <- mkRegU;
  Reg#(Bool) isZero_Z <- mkRegU;
  Reg#(Bool) sign_Z <- mkRegU;
  Reg#(Int#(TAdd#(2, expWidth))) sExp_Z <- mkRegU;
  Reg#(Bit#(sigWidth)) fractB_Z <- mkRegU;
  Reg#(Bit#(3)) roundingMode_Z <- mkRegU;

  Reg#(Bit#(TAdd#(2, sigWidth))) rem_Z <- mkRegU;
  Reg#(Bool) notZeroRem_Z <- mkRegU;
  Reg#(Bit#(TAdd#(2, sigWidth))) sigX_Z <- mkRegU;

  method Bool inReady = (cycleNum <= 1);

  method Action req(
    Bool inValid,
    Bool sqrtOp,
    RawFloat#(expWidth, sigWidth) rawA_S,
    RawFloat#(expWidth, sigWidth) rawB_S,
    Bit#(3) roundingMode
  );
    Bool curInReady = (cycleNum <= 1);

    Bool notSigNaNIn_invalidExc_S_div =
      (rawA_S.isZero && rawB_S.isZero) || (rawA_S.isInf && rawB_S.isInf);
    Bool notSigNaNIn_invalidExc_S_sqrt =
      !rawA_S.isNaN && !rawA_S.isZero && rawA_S.sign;
    Bool majorExc_S = sqrtOp ?
      (isSigNaNRawFloat(rawA_S) || notSigNaNIn_invalidExc_S_sqrt) :
      (isSigNaNRawFloat(rawA_S) || isSigNaNRawFloat(rawB_S) ||
        notSigNaNIn_invalidExc_S_div ||
        (!rawA_S.isNaN && !rawA_S.isInf && rawB_S.isZero));
    Bool isNaN_S = sqrtOp ?
      (rawA_S.isNaN || notSigNaNIn_invalidExc_S_sqrt) :
      (rawA_S.isNaN || rawB_S.isNaN || notSigNaNIn_invalidExc_S_div);
    Bool isInf_S = sqrtOp ? rawA_S.isInf : (rawA_S.isInf || rawB_S.isZero);
    Bool isZero_S = sqrtOp ? rawA_S.isZero : (rawA_S.isZero || rawB_S.isInf);
    Bool sign_S = rawA_S.sign != (!sqrtOp && rawB_S.sign);

    Bool specialCaseA_S = rawA_S.isNaN || rawA_S.isInf || rawA_S.isZero;
    Bool specialCaseB_S = rawB_S.isNaN || rawB_S.isInf || rawB_S.isZero;
    Bool normalCase_S_div = !specialCaseA_S && !specialCaseB_S;
    Bool normalCase_S_sqrt = !specialCaseA_S && !rawA_S.sign;
    Bool normalCase_S = sqrtOp ? normalCase_S_sqrt : normalCase_S_div;

    Bit#(1) bExpTopBit = pack(rawB_S.sExp)[eW];
    Bit#(expWidth) bExpNegLow = ~pack(rawB_S.sExp)[eW - 1 : 0];
    Int#(TAdd#(1, expWidth)) bExpNegSInt = unpack({bExpTopBit, bExpNegLow});
    Int#(TAdd#(3, expWidth)) sExpQuot_S_div =
      signExtend(rawA_S.sExp) + signExtend(bExpNegSInt);

    Int#(TAdd#(3, expWidth)) sevenLit = fromInteger(7 * (2 ** (eW - 2)));
    Bit#(4) satTopNibble = (sevenLit <= sExpQuot_S_div) ?
      4'b0110 : pack(sExpQuot_S_div)[eW + 1 : eW - 2];
    Bit#(TSub#(expWidth, 2)) satLowBits = pack(sExpQuot_S_div)[eW - 3 : 0];
    Int#(TAdd#(2, expWidth)) sSatExpQuot_S_div =
      unpack({satTopNibble, satLowBits});

    Bool aSExpLsb = unpack(pack(rawA_S.sExp)[0]);
    Bool evenSqrt_S = sqrtOp && !aSExpLsb;
    Bool oddSqrt_S = sqrtOp && aSExpLsb;

    Bool idle = (cycleNum == 0);
    Bool entering = curInReady && inValid;
    Bool entering_normalCase = entering && normalCase_S;

    Bool twoBitsOption = (options & divSqrtOpt_twoBitsPerCycle) != 0;
    Bool processTwoBits = (cycleNum >= 3) && twoBitsOption;
    Bool skipCycle2 =
      (cycleNum == 3) && unpack(sigX_Z[sW + 1]) && !twoBitsOption;

    //----------------------------------------------------------------------
    // cycleNum / inReady / rawOutValid
    //----------------------------------------------------------------------
    if (!idle || entering) begin
      Bit#(TLog#(TAdd#(sigWidth, 3))) nextCycleNumTerm1 =
        (entering && !normalCase_S) ? 1 : 0;
      Bit#(TLog#(TAdd#(sigWidth, 3))) nextCycleNumTerm2 = entering_normalCase ?
        (sqrtOp ?
          (aSExpLsb ? fromInteger(sW) : fromInteger(sW + 1)) :
          fromInteger(sW + 2)) :
        0;
      Bit#(TLog#(TAdd#(sigWidth, 3))) nextCycleNumTerm3 =
        (!entering && !skipCycle2) ?
          (cycleNum - (processTwoBits ? 2 : 1)) : 0;
      Bit#(TLog#(TAdd#(sigWidth, 3))) nextCycleNumTerm4 = skipCycle2 ? 1 : 0;
      Bit#(TLog#(TAdd#(sigWidth, 3))) nextCycleNum =
        nextCycleNumTerm1 | nextCycleNumTerm2 | nextCycleNumTerm3 |
        nextCycleNumTerm4;

      cycleNum <= nextCycleNum;
    end

    //----------------------------------------------------------------------
    // latch special-case info, exponent, and rounding mode on entry
    //----------------------------------------------------------------------
    if (entering) begin
      sqrtOp_Z <= sqrtOp;
      majorExc_Z <= majorExc_S;
      isNaN_Z <= isNaN_S;
      isInf_Z <= isInf_S;
      isZero_Z <= isZero_S;
      sign_Z <= sign_S;
      Bit#(TAdd#(1, expWidth)) aSExpHalved = pack(rawA_S.sExp)[eW + 1 : 1];
      Int#(TAdd#(2, expWidth)) sqrtSExp =
        signExtend(unpack(aSExpHalved)) + fromInteger(2 ** (eW - 1));
      sExp_Z <= sqrtOp ? sqrtSExp : sSatExpQuot_S_div;
      roundingMode_Z <= roundingMode;
    end

    //----------------------------------------------------------------------
    // fractB_Z: constant divisor (div) or next bit-weight (sqrt)
    //----------------------------------------------------------------------
    if (entering) begin
      if (!sqrtOp) begin
        fractB_Z <= {pack(rawB_S.sig)[sW - 2 : 0], 1'b0};
      end else if (aSExpLsb) begin
        fractB_Z <= fromInteger(2 ** (sW - 2));
      end else begin
        fractB_Z <= fromInteger(2 ** (sW - 1));
      end
    end else if (!curInReady && sqrtOp_Z) begin
      fractB_Z <= processTwoBits ? (fractB_Z >> 2) : (fractB_Z >> 1);
    end

    //----------------------------------------------------------------------
    // core digit recurrence: rem / trialTerm / trialRem
    //----------------------------------------------------------------------
    Bit#(TAdd#(sigWidth, 4)) remTerm1 =
      (curInReady && !oddSqrt_S) ? (zeroExtend(pack(rawA_S.sig)) << 1) : 0;
    Bit#(2) aSigBits_hi = pack(rawA_S.sig)[sW - 1 : sW - 2];
    Bit#(3) remTerm2_hi = zeroExtend(aSigBits_hi) - 1;
    Bit#(TSub#(sigWidth, 2)) aSigBits_lo = pack(rawA_S.sig)[sW - 3 : 0];
    Bit#(TAdd#(sigWidth, 1)) remTerm2_lo =
      zeroExtend(aSigBits_lo) << 3;
    Bit#(TAdd#(sigWidth, 4)) remTerm2 =
      (curInReady && oddSqrt_S) ?
        zeroExtend({remTerm2_hi, remTerm2_lo}) : 0;
    Bit#(TAdd#(sigWidth, 4)) remTerm3 =
      (!curInReady) ? (zeroExtend(rem_Z) << 1) : 0;
    Bit#(TAdd#(sigWidth, 4)) rem = remTerm1 | remTerm2 | remTerm3;

    Bit#(TAdd#(sigWidth, 3)) trialTermT1 =
      (curInReady && !sqrtOp) ? (zeroExtend(pack(rawB_S.sig)) << 1) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTermT2 =
      (curInReady && evenSqrt_S) ? fromInteger(2 ** sW) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTermT3 =
      (curInReady && oddSqrt_S) ? fromInteger(5 * (2 ** (sW - 1))) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTermT4 =
      (!curInReady) ? zeroExtend(fractB_Z) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTermT5 =
      (!curInReady && !sqrtOp_Z) ? fromInteger(2 ** sW) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTermT6 =
      (!curInReady && sqrtOp_Z) ? (zeroExtend(sigX_Z) << 1) : 0;
    Bit#(TAdd#(sigWidth, 3)) trialTerm =
      trialTermT1 | trialTermT2 | trialTermT3 | trialTermT4 | trialTermT5 |
      trialTermT6;

    Int#(TAdd#(sigWidth, 6)) trialRem =
      signExtend(unpack({1'b0, rem})) - signExtend(unpack({1'b0, trialTerm}));
    Bool newBit = (0 <= trialRem);

    Bit#(TAdd#(sigWidth, 6)) trialRemAsUInt = pack(trialRem);
    Bit#(TAdd#(sigWidth, 2)) nextRem_Z =
      (newBit ? trialRemAsUInt : zeroExtend(rem))[sW + 1 : 0];
    Bit#(TAdd#(sigWidth, 3)) rem2 = zeroExtend(nextRem_Z) << 1;

    Bit#(sigWidth) fractB_Z_sr1 = fractB_Z >> 1;
    Bit#(TAdd#(sigWidth, 3)) sigX_Z_sl1 = zeroExtend(sigX_Z) << 1;
    Bit#(TAdd#(sigWidth, 3)) trialTerm2_newBit0_sqrt =
      zeroExtend(fractB_Z_sr1) | sigX_Z_sl1;
    Bit#(TAdd#(sigWidth, 3)) trialTerm2_newBit0_div =
      zeroExtend(fractB_Z) | fromInteger(2 ** sW);
    Bit#(TAdd#(sigWidth, 3)) trialTerm2_newBit0 =
      sqrtOp_Z ? trialTerm2_newBit0_sqrt : trialTerm2_newBit0_div;
    Bit#(TAdd#(sigWidth, 1)) fractB_Z_sl1 = zeroExtend(fractB_Z) << 1;
    Bit#(TAdd#(sigWidth, 3)) trialTerm2_newBit1 =
      trialTerm2_newBit0 | (sqrtOp_Z ? zeroExtend(fractB_Z_sl1) : 0);

    Int#(TAdd#(sigWidth, 8)) trialRem2_branchA =
      (signExtend(trialRem) << 1) -
        signExtend(unpack({1'b0, trialTerm2_newBit1}));
    Bit#(TAdd#(sigWidth, 4)) rem_Z_sl2 = zeroExtend(rem_Z) << 2;
    Bit#(TAdd#(sigWidth, 3)) rem_Z_sl2_trunc = rem_Z_sl2[sW + 2 : 0];
    Int#(TAdd#(sigWidth, 5)) trialRem2_branchB =
      signExtend(unpack({1'b0, rem_Z_sl2_trunc})) -
        signExtend(unpack({1'b0, trialTerm2_newBit0}));
    Bool newBit2 = newBit ? (0 <= trialRem2_branchA) : (0 <= trialRem2_branchB);

    Bool nextNotZeroRem_Z =
      (curInReady || newBit) ? (trialRem != 0) : notZeroRem_Z;
    Bool nextNotZeroRem_Z_2 =
      (processTwoBits && newBit && (0 < trialRem2_branchA)) ||
      (processTwoBits && !newBit && (0 < trialRem2_branchB)) ||
      (!(processTwoBits && newBit2) && nextNotZeroRem_Z);

    Bit#(TAdd#(sigWidth, 2)) nextRem_Z_2Term1 =
      (processTwoBits && newBit2) ?
        pack(newBit ? trialRem2_branchA : signExtend(trialRem2_branchB))[sW + 1 : 0] :
        0;
    Bit#(TAdd#(sigWidth, 2)) nextRem_Z_2Term2 =
      (processTwoBits && !newBit2) ? rem2[sW + 1 : 0] : 0;
    Bit#(TAdd#(sigWidth, 2)) nextRem_Z_2Term3 =
      (!processTwoBits) ? nextRem_Z : 0;
    Bit#(TAdd#(sigWidth, 2)) nextRem_Z_2 =
      nextRem_Z_2Term1 | nextRem_Z_2Term2 | nextRem_Z_2Term3;

    Bit#(TAdd#(sigWidth, 3)) bitMaskWide = 1 << cycleNum;
    Bit#(TAdd#(sigWidth, 2)) bitMask = truncate(bitMaskWide >> 2);

    if (entering || !curInReady) begin
      notZeroRem_Z <= nextNotZeroRem_Z_2;
      rem_Z <= nextRem_Z_2;

      Bit#(TAdd#(sigWidth, 2)) sigXTerm1 =
        (curInReady && !sqrtOp) ?
          (zeroExtend(pack(newBit)) << (sW + 1)) : 0;
      Bit#(TAdd#(sigWidth, 2)) sigXTerm2 =
        (curInReady && sqrtOp) ? fromInteger(2 ** sW) : 0;
      Bit#(TAdd#(sigWidth, 2)) sigXTerm3 =
        (curInReady && oddSqrt_S) ?
          (zeroExtend(pack(newBit)) << (sW - 1)) : 0;
      Bit#(TAdd#(sigWidth, 2)) sigXTerm4 = (!curInReady) ? sigX_Z : 0;
      Bit#(TAdd#(sigWidth, 2)) sigXTerm5 =
        (!curInReady && newBit) ? bitMask : 0;
      Bit#(TAdd#(sigWidth, 2)) sigXTerm6 =
        (processTwoBits && newBit2) ? (bitMask >> 1) : 0;
      sigX_Z <=
        sigXTerm1 | sigXTerm2 | sigXTerm3 | sigXTerm4 | sigXTerm5 |
        sigXTerm6;
    end
  endmethod

  method Bool rawOutValid_div = (cycleNum == 1) && !sqrtOp_Z;
  method Bool rawOutValid_sqrt = (cycleNum == 1) && sqrtOp_Z;
  method Bit#(3) roundingModeOut = roundingMode_Z;
  method Bool invalidExc = majorExc_Z && isNaN_Z;
  method Bool infiniteExc = majorExc_Z && !isNaN_Z;
  method RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
    RawFloat#(expWidth, TAdd#(2, sigWidth)) out;
    out.isNaN = isNaN_Z;
    out.isInf = isInf_Z;
    out.isZero = isZero_Z;
    out.sign = sign_Z;
    out.sExp = sExp_Z;
    out.sig = unpack((zeroExtend(sigX_Z) << 1) | zeroExtend(pack(notZeroRem_Z)));
    return out;
  endmethod
endmodule

// Mirrors DivSqrtRecFNToRaw_small: decodes the recoded a/b inputs and
// otherwise just passes the RawFN_small interface through.
interface DivSqrtRecFNToRaw_small#(numeric type expWidth, numeric type sigWidth);
  (* always_ready *)
  method Bool inReady;
  (* always_ready, always_enabled *)
  method Action req(
    Bool inValid,
    Bool sqrtOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode
  );
  (* always_ready *)
  method Bool rawOutValid_div;
  (* always_ready *)
  method Bool rawOutValid_sqrt;
  (* always_ready *)
  method Bit#(3) roundingModeOut;
  (* always_ready *)
  method Bool invalidExc;
  (* always_ready *)
  method Bool infiniteExc;
  (* always_ready *)
  method RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
endinterface

module mkDivSqrtRecFNToRaw_small#(Bit#(5) options)
    (DivSqrtRecFNToRaw_small#(expWidth, sigWidth))
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );
  DivSqrtRawFN_small#(expWidth, sigWidth) divSqrtRawFN <-
    mkDivSqrtRawFN_small(options);

  method Bool inReady = divSqrtRawFN.inReady;

  method Action req(
    Bool inValid,
    Bool sqrtOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode
  );
    divSqrtRawFN.req(
      inValid, sqrtOp, rawFloatFromRecFN(a), rawFloatFromRecFN(b),
      roundingMode);
  endmethod

  method Bool rawOutValid_div = divSqrtRawFN.rawOutValid_div;
  method Bool rawOutValid_sqrt = divSqrtRawFN.rawOutValid_sqrt;
  method Bit#(3) roundingModeOut = divSqrtRawFN.roundingModeOut;
  method Bool invalidExc = divSqrtRawFN.invalidExc;
  method Bool infiniteExc = divSqrtRawFN.infiniteExc;
  method RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut = divSqrtRawFN.rawOut;
endmodule

// Mirrors DivSqrtRecFN_small: adds the control/detectTininess input and the
// final RoundRawFNToRecFN rounding stage. `control` (this project's 1-bit
// detectTininess, matching addRecFN/mulRecFN/mulAddRecFN) is intentionally
// NOT latched alongside roundingMode — Chisel wires io.detectTininess
// straight into the rounding stage live every cycle, same as this project's
// `control` input elsewhere, so `result` takes it as a method argument
// rather than threading it through `req`. The recoded result and exception
// flags are returned together (as in mkAddRecFN/mkMulRecFN/mkMulAddRecFN)
// so the rounding logic is computed once, not duplicated across two
// separately-read output methods; the spec.v wrapper splits the combined
// bus the same way the combinational ports already do.
interface DivSqrtRecFN_small#(numeric type expWidth, numeric type sigWidth);
  (* always_ready *)
  method Bool inReady;
  (* always_ready, always_enabled *)
  method Action req(
    Bool inValid,
    Bool sqrtOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode
  );
  (* always_ready *)
  method Bool outValid_div;
  (* always_ready *)
  method Bool outValid_sqrt;
  (* always_ready *)
  method Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception)
    result(Bit#(1) control);
endinterface

module mkDivSqrtRecFN_small#(Bit#(5) options)
    (DivSqrtRecFN_small#(expWidth, sigWidth))
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );
  DivSqrtRecFNToRaw_small#(expWidth, sigWidth) divSqrtRecFNToRaw <-
    mkDivSqrtRecFNToRaw_small(options);

  method Bool inReady = divSqrtRecFNToRaw.inReady;

  method Action req(
    Bool inValid,
    Bool sqrtOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode
  );
    divSqrtRecFNToRaw.req(inValid, sqrtOp, a, b, roundingMode);
  endmethod

  method Bool outValid_div = divSqrtRecFNToRaw.rawOutValid_div;
  method Bool outValid_sqrt = divSqrtRecFNToRaw.rawOutValid_sqrt;

  method Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception)
    result(Bit#(1) control);
    RoundRawFNToRecFN#(expWidth, sigWidth) roundRawFNToRecFN =
      mkRoundRawFNToRecFN(0);
    return roundRawFNToRecFN(
      divSqrtRecFNToRaw.invalidExc,
      divSqrtRecFNToRaw.infiniteExc,
      divSqrtRecFNToRaw.rawOut,
      divSqrtRecFNToRaw.roundingModeOut,
      control
    );
  endmethod
endmodule
