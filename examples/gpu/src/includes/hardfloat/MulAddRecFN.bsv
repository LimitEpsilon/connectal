import Vector::*;
import FloatingPoint::*;
import HardFloat::*;

// Mirrors HardFloat Chisel: MulAddRecFNToRaw_preMul + (mulAddA*mulAddB+mulAddC)
// + MulAddRecFNToRaw_postMul → MulAddRecFN (see hardfloat MulAddRecFN.scala).
//
// op encodes the fused operation:
//   op[1]: negate the A*B product's sign before combining with C
//   op[0]: force doSubMags (subtract magnitudes instead of add)
// (addRecFN's "add"/"sub" and mulRecFN's pure multiply are both expressible
// as mulAdd with a synthesized identity operand; see mulAddRecFN_spec.v.)

typedef TAdd#(TAdd#(sigWidth, TAdd#(sigWidth, sigWidth)), 3) MulAddSigSumWidth#(numeric type sigWidth);

// floor(sigWidth / 2); BSV's TDiv#(n,2) is ceiling division, which differs
// from Chisel's plain "sigWidth >> 1" for odd sigWidth (e.g. f16's 11).
typedef TDiv#(TSub#(sigWidth, 1), 2) MulAddHalfSigWidth#(numeric type sigWidth);

// Mirrors the Chisel MulAddRecFN_interIo bundle: the values that flow from
// the preMul stage into the postMul stage. Kept as an explicit struct (not
// inlined) so a future pipelined version can register exactly this value,
// the same way the reference Verilog wires mulAddRecFNToRaw_preMul's
// intermed_* outputs into mulAddRecFNToRaw_postMul's inputs.
typedef struct {
  Bool isSigNaNAny;
  Bool isNaNAOrB;
  Bool isInfA;
  Bool isZeroA;
  Bool isInfB;
  Bool isZeroB;
  Bool signProd;
  Bool isNaNC;
  Bool isInfC;
  Bool isZeroC;
  Int#(TAdd#(2, expWidth)) sExpSum;
  Bool doSubMags;
  Bool cIsDominant;
  Bit#(TLog#(TAdd#(1, sigWidth))) cDom_cAlignDist;
  Bit#(TAdd#(2, sigWidth)) highAlignedSigC;
  Bit#(1) bit0AlignedSigC;
} MulAddInterIo#(numeric type expWidth, numeric type sigWidth)
  deriving (Bits, Eq);

// Mirrors MulAddRecFNToRaw_preMul: unpacks operands, aligns C against the
// A*B product, and produces the A*B multiplier inputs plus everything
// postMul needs once the product is known.
function Tuple4#(
    Bit#(sigWidth), Bit#(sigWidth), Bit#(TAdd#(sigWidth, sigWidth)),
    MulAddInterIo#(expWidth, sigWidth)
  ) mulAddRawFN_preMul(
    Bit#(2) op,
    RawFloat#(expWidth, sigWidth) rawA,
    RawFloat#(expWidth, sigWidth) rawB,
    RawFloat#(expWidth, sigWidth) rawC
  )
  provisos (
    Add#(_3, TLog#(MulAddSigSumWidth#(sigWidth)), TAdd#(2, expWidth)),
    Add#(TLog#(TAdd#(1, sigWidth)), _5, TLog#(MulAddSigSumWidth#(sigWidth)))
  );
    Integer eW = valueOf(expWidth);
    Integer sW = valueOf(sigWidth);
    Integer sigSumWidth = 3 * sW + 3;

    Bool signProd = (rawA.sign != rawB.sign) != unpack(op[1]);

    Int#(TAdd#(3, expWidth)) sExpAB =
      signExtend(rawA.sExp) + signExtend(rawB.sExp);
    Int#(TAdd#(4, expWidth)) sExpAlignedProd =
      signExtend(sExpAB) + fromInteger(sW + 3 - (2 ** eW));

    Bool doSubMags = (signProd != rawC.sign) != unpack(op[0]);

    Int#(TAdd#(5, expWidth)) sNatCAlignDist =
      signExtend(sExpAlignedProd) - signExtend(rawC.sExp);
    Bit#(TAdd#(2, expWidth)) posNatCAlignDist =
      pack(sNatCAlignDist)[eW + 1 : 0];
    Bool isMinCAlign = rawA.isZero || rawB.isZero || (sNatCAlignDist < 0);
    Bool cIsDominant =
      !rawC.isZero && (isMinCAlign || (posNatCAlignDist <= fromInteger(sW)));

    Int#(TAdd#(5, expWidth)) sExpAlignedProdMinusSig =
      signExtend(sExpAlignedProd) - fromInteger(sW);
    Int#(TAdd#(5, expWidth)) sExpSumWide =
      cIsDominant ? signExtend(rawC.sExp) : sExpAlignedProdMinusSig;
    Int#(TAdd#(2, expWidth)) sExpSum = unpack(pack(sExpSumWide)[eW + 1 : 0]);

    Bit#(TLog#(MulAddSigSumWidth#(sigWidth))) cAlignDist =
      isMinCAlign ? 0 :
        ((posNatCAlignDist < fromInteger(sigSumWidth - 1)) ?
          truncate(posNatCAlignDist) : fromInteger(sigSumWidth - 1));

    Bit#(TAdd#(1, sigWidth)) cSigOrInv =
      doSubMags ? ~pack(rawC.sig) : pack(rawC.sig);
    Bit#(TSub#(TAdd#(MulAddSigSumWidth#(sigWidth), 2), sigWidth)) cFillBits =
      pack(replicate(doSubMags));
    Int#(TAdd#(MulAddSigSumWidth#(sigWidth), 3)) extComplSigC =
      unpack({cSigOrInv, cFillBits});
    Int#(TAdd#(MulAddSigSumWidth#(sigWidth), 3)) mainAlignedSigC =
      extComplSigC >> cAlignDist;

    Integer cGrainAlign = (sigSumWidth - sW - 1) % 4;
    Bit#(TAdd#(4, sigWidth)) cGrainAlignedSig =
      zeroExtend(pack(rawC.sig)) << fromInteger(cGrainAlign);
    Bit#(TDiv#(TAdd#(4, sigWidth), 4)) cReduced4Sig =
      orReduceBy4(cGrainAlignedSig);
    Integer cExtraMaskHi = (sigSumWidth - 1) / 4;
    Integer cExtraMaskLo = (sigSumWidth - sW - 1) / 4;
    Bit#(TDiv#(TAdd#(4, sigWidth), 4)) cExtraMask =
      lowMask(cAlignDist >> 2, cExtraMaskHi, cExtraMaskLo);
    Bool reduced4CExtra = orR(cReduced4Sig & cExtraMask);

    Bit#(MulAddSigSumWidth#(sigWidth)) mainAlignedSigCShifted3 =
      pack(mainAlignedSigC)[sigSumWidth + 2 : 3];
    Bool alignedSigCStickyBit = doSubMags ?
      (andR(pack(mainAlignedSigC)[2:0]) && !reduced4CExtra) :
      (orR(pack(mainAlignedSigC)[2:0]) || reduced4CExtra);
    Bit#(TAdd#(MulAddSigSumWidth#(sigWidth), 1)) alignedSigC =
      {mainAlignedSigCShifted3, pack(alignedSigCStickyBit)};

    Bit#(sigWidth) mulAddA = truncate(pack(rawA.sig));
    Bit#(sigWidth) mulAddB = truncate(pack(rawB.sig));
    Bit#(TAdd#(sigWidth, sigWidth)) mulAddC =
      pack(alignedSigC)[2 * sW : 1];

    Bool isSigNaNAny =
      isSigNaNRawFloat(rawA) || isSigNaNRawFloat(rawB) || isSigNaNRawFloat(rawC);
    Bool isNaNAOrB = rawA.isNaN || rawB.isNaN;
    Bit#(TAdd#(2, sigWidth)) highAlignedSigC =
      pack(alignedSigC)[sigSumWidth - 1 : 2 * sW + 1];
    Bit#(1) bit0AlignedSigC = pack(alignedSigC)[0];
    Bit#(TLog#(TAdd#(1, sigWidth))) cDom_cAlignDist = truncate(cAlignDist);

    MulAddInterIo#(expWidth, sigWidth) interIo = MulAddInterIo {
      isSigNaNAny: isSigNaNAny,
      isNaNAOrB: isNaNAOrB,
      isInfA: rawA.isInf,
      isZeroA: rawA.isZero,
      isInfB: rawB.isInf,
      isZeroB: rawB.isZero,
      signProd: signProd,
      isNaNC: rawC.isNaN,
      isInfC: rawC.isInf,
      isZeroC: rawC.isZero,
      sExpSum: sExpSum,
      doSubMags: doSubMags,
      cIsDominant: cIsDominant,
      cDom_cAlignDist: cDom_cAlignDist,
      highAlignedSigC: highAlignedSigC,
      bit0AlignedSigC: bit0AlignedSigC
    };

    return tuple4(mulAddA, mulAddB, mulAddC, interIo);
endfunction

// Mirrors MulAddRecFNToRaw_postMul: re-aligns the A*B product against
// highAlignedSigC, normalizes, and prepares rounding inputs for both the
// "C dominant" and "C not dominant" cases.
function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth)))
  mulAddRawFN_postMul(
    MulAddInterIo#(expWidth, sigWidth) interIo,
    Bit#(TAdd#(TAdd#(sigWidth, sigWidth), 1)) mulAddResult,
    Bit#(3) roundingMode
  )
  provisos (
    Add#(TAdd#(1, TLog#(TAdd#(sigWidth, 2))), _6, TAdd#(3, expWidth)),
    Add#(sigWidth, 2, TDiv#(TAdd#(TAdd#(sigWidth, sigWidth), 4), 2))
  );
    Integer eW = valueOf(expWidth);
    Integer sW = valueOf(sigWidth);
    Integer sigSumWidth = 3 * sW + 3;

    Bool signProd = interIo.signProd;
    Bool doSubMags = interIo.doSubMags;
    Bool cIsDominant = interIo.cIsDominant;
    Int#(TAdd#(2, expWidth)) sExpSum = interIo.sExpSum;
    Bit#(TAdd#(2, sigWidth)) highAlignedSigC = interIo.highAlignedSigC;
    Bit#(1) bit0AlignedSigC = interIo.bit0AlignedSigC;
    Bit#(TLog#(TAdd#(1, sigWidth))) cDom_cAlignDist = interIo.cDom_cAlignDist;
    Bool opSignC = signProd != doSubMags;
    Bool roundingMode_min = (roundingMode == round_min);

    Bit#(TAdd#(2, sigWidth)) sigSumHigh =
      unpack(mulAddResult[2 * sW]) ?
        (highAlignedSigC + 1) : highAlignedSigC;
    Bit#(MulAddSigSumWidth#(sigWidth)) sigSum =
      {sigSumHigh, mulAddResult[2 * sW - 1 : 0], bit0AlignedSigC};

    // ---- C-dominant case ----
    Bool cDom_sign = opSignC;
    Int#(TAdd#(3, expWidth)) cDom_sExp =
      signExtend(sExpSum) - (doSubMags ? 1 : 0);
    Bit#(2) cDom_absSigSum_midPart = highAlignedSigC[sW + 1 : sW];
    Bit#(TSub#(TAdd#(sigWidth, sigWidth), 1)) cDom_absSigSum_lowPart =
      sigSum[sigSumWidth - 3 : sW + 2];
    Bit#(TAdd#(2, TAdd#(sigWidth, sigWidth))) cDom_absSigSum = doSubMags ?
      ~sigSum[sigSumWidth - 1 : sW + 1] :
      {1'b0, cDom_absSigSum_midPart, cDom_absSigSum_lowPart};
    Bit#(sigWidth) cDom_absSigSumExtra_subSlice = sigSum[sW : 1];
    Bit#(TAdd#(sigWidth, 1)) cDom_absSigSumExtra_addSlice = sigSum[sW + 1 : 1];
    Bool cDom_absSigSumExtra = doSubMags ?
      orR(~cDom_absSigSumExtra_subSlice) : orR(cDom_absSigSumExtra_addSlice);

    Bit#(TAdd#(TAdd#(sigWidth, TAdd#(sigWidth, sigWidth)), 2)) cDom_shiftContainer =
      zeroExtend(cDom_absSigSum) << cDom_cAlignDist;
    Bit#(TAdd#(sigWidth, 5)) cDom_mainSig =
      cDom_shiftContainer[2 * sW + 1 : sW - 3];

    Integer cDomShamt4 = (4 - ((sW + 1) % 4)) % 4;
    Bit#(sigWidth) cDom_absSigSum_low = cDom_absSigSum[sW - 1 : 0];
    Bit#(TAdd#(sigWidth, 3)) cDom_low4Shifted =
      zeroExtend(cDom_absSigSum_low) << fromInteger(cDomShamt4);
    Bit#(TDiv#(TAdd#(sigWidth, 3), 4)) cDom_reduced4Sig =
      orReduceBy4(cDom_low4Shifted);
    Bit#(TDiv#(TAdd#(sigWidth, 3), 4)) cDom_extraMask =
      lowMask(cDom_cAlignDist >> 2, 0, sW / 4);
    Bool cDom_reduced4SigExtra = orR(cDom_reduced4Sig & cDom_extraMask);

    Bool cDom_stickyBit =
      orR(cDom_mainSig[2:0]) || cDom_reduced4SigExtra || cDom_absSigSumExtra;
    Bit#(TAdd#(sigWidth, 3)) cDom_sig =
      {cDom_mainSig[sW + 4 : 3], pack(cDom_stickyBit)};

    // ---- C-not-dominant case ----
    Bool notCDom_signSigSum = unpack(sigSum[2 * sW + 3]);
    Bit#(TAdd#(TAdd#(sigWidth, sigWidth), 3)) sigSumLow =
      pack(sigSum)[2 * sW + 2 : 0];
    Bit#(TAdd#(TAdd#(sigWidth, sigWidth), 4)) notCDom_absSigSum =
      notCDom_signSigSum ?
        zeroExtend(~sigSumLow) :
        (zeroExtend(sigSumLow) + zeroExtend(pack(doSubMags)));

    Bit#(TAdd#(sigWidth, 2)) notCDom_reduced2AbsSigSum =
      orReduceBy2(notCDom_absSigSum);
    Bit#(TLog#(TAdd#(sigWidth, 2))) notCDom_normDistReduced2 =
      countLeadingZeroes(notCDom_reduced2AbsSigSum);
    Bit#(TAdd#(1, TLog#(TAdd#(sigWidth, 2)))) notCDom_nearNormDist =
      {notCDom_normDistReduced2, 1'b0};

    Int#(TAdd#(3, expWidth)) notCDom_sExp =
      signExtend(sExpSum) - unpack(zeroExtend(notCDom_nearNormDist));

    Bit#(TAdd#(TAdd#(TAdd#(sigWidth, sigWidth), TAdd#(sigWidth, sigWidth)), 8)) notCDom_shiftContainer =
      zeroExtend(notCDom_absSigSum) << notCDom_nearNormDist;
    Bit#(TAdd#(sigWidth, 5)) notCDom_mainSig =
      notCDom_shiftContainer[2 * sW + 3 : sW - 1];

    Integer notCDomShamt2 = (sW / 2) % 2;
    Bit#(TAdd#(1, MulAddHalfSigWidth#(sigWidth))) notCDom_reduced2AbsSigSum_low =
      notCDom_reduced2AbsSigSum[sW / 2 : 0];
    Bit#(TAdd#(MulAddHalfSigWidth#(sigWidth), 2)) notCDom_low2Shifted =
      zeroExtend(notCDom_reduced2AbsSigSum_low) << fromInteger(notCDomShamt2);
    Bit#(TDiv#(TAdd#(MulAddHalfSigWidth#(sigWidth), 2), 2)) notCDom_reduced4Sig =
      orReduceBy2(notCDom_low2Shifted);
    Bit#(TDiv#(TAdd#(MulAddHalfSigWidth#(sigWidth), 2), 2)) notCDom_extraMask =
      lowMask(notCDom_normDistReduced2 >> 1, 0, (sW + 2) / 4);
    Bool notCDom_reduced4SigExtra = orR(notCDom_reduced4Sig & notCDom_extraMask);

    Bool notCDom_stickyBit =
      orR(notCDom_mainSig[2:0]) || notCDom_reduced4SigExtra;
    Bit#(TAdd#(sigWidth, 3)) notCDom_sig =
      {notCDom_mainSig[sW + 4 : 3], pack(notCDom_stickyBit)};

    Bit#(2) notCDom_sig_topBits = pack(notCDom_sig)[sW + 2 : sW + 1];
    Bool notCDom_completeCancellation = notCDom_sig_topBits == 0;
    Bool notCDom_sign = notCDom_completeCancellation ?
      roundingMode_min : (signProd != notCDom_signSigSum);

    //--------------------------------------------------------------------
    // combine special cases with the C-dominant / not-dominant results
    //--------------------------------------------------------------------
    Bool notNaN_isInfProd = interIo.isInfA || interIo.isInfB;
    Bool notNaN_isInfOut = notNaN_isInfProd || interIo.isInfC;
    Bool notNaN_addZeros = (interIo.isZeroA || interIo.isZeroB) && interIo.isZeroC;

    Bool invalidExc =
      interIo.isSigNaNAny ||
      (interIo.isInfA && interIo.isZeroB) ||
      (interIo.isZeroA && interIo.isInfB) ||
      (!interIo.isNaNAOrB && (interIo.isInfA || interIo.isInfB) &&
        interIo.isInfC && doSubMags);

    RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
    rawOut.isNaN = interIo.isNaNAOrB || interIo.isNaNC;
    rawOut.isInf = notNaN_isInfOut;
    rawOut.isZero =
      notNaN_addZeros || (!cIsDominant && notCDom_completeCancellation);
    rawOut.sign =
      (notNaN_isInfProd && signProd) ||
      (interIo.isInfC && opSignC) ||
      (notNaN_addZeros && !roundingMode_min && signProd && opSignC) ||
      (notNaN_addZeros && roundingMode_min && (signProd || opSignC)) ||
      (!notNaN_isInfOut && !notNaN_addZeros &&
        (cIsDominant ? cDom_sign : notCDom_sign));
    Int#(TAdd#(3, expWidth)) sExpOutWide = cIsDominant ? cDom_sExp : notCDom_sExp;
    rawOut.sExp = unpack(pack(sExpOutWide)[eW + 1 : 0]);
    rawOut.sig = unpack(cIsDominant ? cDom_sig : notCDom_sig);

    return tuple2(invalidExc, rawOut);
endfunction

typedef function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) _
  ( Bit#(2) op,
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b,
    RawFloat#(expWidth, sigWidth) c,
    Bit#(3) roundingMode
  ) MulAddRawFN#(
  numeric type expWidth, numeric type sigWidth
);

// Mirrors the Verilog mulAddRecFNToRaw module: wires preMul's outputs
// (mulAddA, mulAddB, mulAddC, and the interIo struct) through the A*B
// multiply and into postMul. preMul and postMul are plain combinational
// functions with no register between them here (matching the reference,
// which has none either — see mulAddRecFNToRaw in mulAddRecFN.v), but
// keeping them separate leaves an obvious seam for a future pipelined
// version to register interIo/mulAddA/mulAddB/mulAddC between the two.
function MulAddRawFN#(expWidth, sigWidth) mkMulAddRawFN
  provisos (
    Add#(_3, TLog#(MulAddSigSumWidth#(sigWidth)), TAdd#(2, expWidth)),
    Add#(TLog#(TAdd#(1, sigWidth)), _5, TLog#(MulAddSigSumWidth#(sigWidth))),
    Add#(TAdd#(1, TLog#(TAdd#(sigWidth, 2))), _6, TAdd#(3, expWidth)),
    Add#(sigWidth, 2, TDiv#(TAdd#(TAdd#(sigWidth, sigWidth), 4), 2))
  );

  function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) f(
    Bit#(2) op,
    RawFloat#(expWidth, sigWidth) rawA,
    RawFloat#(expWidth, sigWidth) rawB,
    RawFloat#(expWidth, sigWidth) rawC,
    Bit#(3) roundingMode
  );
    match {.mulAddA, .mulAddB, .mulAddC, .interIo} =
      mulAddRawFN_preMul(op, rawA, rawB, rawC);

    Bit#(TAdd#(sigWidth, sigWidth)) mulProd =
      zeroExtend(mulAddA) * zeroExtend(mulAddB);
    Bit#(TAdd#(TAdd#(sigWidth, sigWidth), 1)) mulAddResult =
      zeroExtend(mulProd) + zeroExtend(mulAddC);

    return mulAddRawFN_postMul(interIo, mulAddResult, roundingMode);
  endfunction

  return f;
endfunction

typedef function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) _
  ( Bit#(2) op,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) c,
    Bit#(3) roundingMode,
    Bool detectTininess
  ) MulAddRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function MulAddRecFN#(expWidth, sigWidth) mkMulAddRecFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth),
    Add#(_3, TLog#(MulAddSigSumWidth#(sigWidth)), TAdd#(2, expWidth)),
    Add#(TLog#(TAdd#(1, sigWidth)), _5, TLog#(MulAddSigSumWidth#(sigWidth))),
    Add#(TAdd#(1, TLog#(TAdd#(sigWidth, 2))), _6, TAdd#(3, expWidth)),
    Add#(sigWidth, 2, TDiv#(TAdd#(TAdd#(sigWidth, sigWidth), 4), 2))
  );

  function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) f(
    Bit#(2) op,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) c,
    Bit#(3) roundingMode,
    Bool detectTininess
  );
    RawFloat#(expWidth, sigWidth) a_raw = rawFloatFromRecFN(a);
    RawFloat#(expWidth, sigWidth) b_raw = rawFloatFromRecFN(b);
    RawFloat#(expWidth, sigWidth) c_raw = rawFloatFromRecFN(c);
    MulAddRawFN#(expWidth, sigWidth) mulAddRawFn = mkMulAddRawFN;
    match {.invalidExc, .rawOut} = mulAddRawFn(op, a_raw, b_raw, c_raw, roundingMode);

    RoundRawFNToRecFN#(expWidth, sigWidth) roundRawFNToRecFN =
      mkRoundRawFNToRecFN(0);
    return roundRawFNToRecFN(
      invalidExc,
      False,
      rawOut,
      roundingMode,
      pack(detectTininess)
    );
  endfunction

  return f;
endfunction
