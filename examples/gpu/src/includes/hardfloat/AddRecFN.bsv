import Vector::*;
import FloatingPoint::*;
import HardFloat::*;

typedef function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) _
  ( Bool subOp,
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b,
    Bit#(3) roundingMode
  ) AddRawFN#(
  numeric type expWidth, numeric type sigWidth
);

function AddRawFN#(expWidth, sigWidth) mkAddRawFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) f(
    Bool subOp,
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b,
    Bit#(3) roundingMode
  );
    Integer alignDistWidth = valueOf(TLog#(sigWidth));
    Integer sW = valueOf(sigWidth);
    Integer eW = valueOf(expWidth);

    Bool effSignB = unpack(pack(b.sign) ^ pack(subOp));
    Bool eqSigns = a.sign == effSignB;
    Bool notEqSigns_signZero = roundingMode == round_min;
    Int#(TAdd#(2, expWidth)) sDiffExps = a.sExp - b.sExp;
    Bit#(TAdd#(2, expWidth)) bDiffExps = pack(sDiffExps);
    Bit#(TLog#(sigWidth)) modNatAlignDist = 
        pack((sDiffExps < 0) ? b.sExp - a.sExp : sDiffExps)[alignDistWidth - 1 : 0];
    Bit#(TLog#(sigWidth)) bDiffExps_alignLow = bDiffExps[alignDistWidth - 1 : 0];
    Bool isMaxAlign =
      (sDiffExps >> alignDistWidth) != 0 &&
        ((sDiffExps >> alignDistWidth) != -1 || bDiffExps_alignLow == 0);
    Bit#(TLog#(sigWidth)) alignDist = isMaxAlign ? fromInteger(2 ** alignDistWidth - 1) : modNatAlignDist;
    Bool closeSubMags = !eqSigns && !isMaxAlign && (modNatAlignDist <= 1);
    
    Int#(TAdd#(3, sigWidth)) close_alignedSigA = 
      ((0 <= sDiffExps && (bDiffExps[0] == 1)) ? signExtend(unpack(pack(a.sig))) << 2 : 0) |
      ((0 <= sDiffExps && (bDiffExps[0] == 0)) ? signExtend(unpack(pack(a.sig))) << 1 : 0) |
      (sDiffExps < 0                           ? signExtend(unpack(pack(a.sig)))      : 0);
    Int#(TAdd#(3, sigWidth)) close_sSigSum = close_alignedSigA - unpack(zeroExtend(pack(b.sig << 1)));
    Bit#(TAdd#(sigWidth, 2)) close_sigSum = pack(close_sSigSum < 0 ? -close_sSigSum : close_sSigSum)[sW + 1 : 0];
    Bit#(TAdd#(sigWidth, 3)) close_adjustedSigSum = zeroExtend(close_sigSum) << (fromInteger(sW) & 1);
    Bit#(TDiv#(TAdd#(sigWidth, 3), 2)) close_reduced2SigSum = orReduceBy2(close_adjustedSigSum);
    Bit#(TLog#(TDiv#(TAdd#(sigWidth, 3), 2)))
      close_normDistReduced2 = countLeadingZeroes(close_reduced2SigSum);
    Bit#(TLog#(sigWidth)) close_nearNormDist = ({close_normDistReduced2, 1'b0} - fromInteger(2 * (1 - sW % 2)))[alignDistWidth - 1 : 0];
    Bit#(TAdd#(sigWidth, 3)) close_sigOut = (zeroExtend(close_sigSum) << close_nearNormDist) << 1;
    Bit#(2) close_sigOut_top = pack(close_sigOut)[sW + 2 : sW + 1];
    Bool close_totalCancellation = !(orR(close_sigOut_top));
    Bool close_notTotalCancellation_signOut = unpack(pack(a.sign) ^ pack(close_sSigSum < 0));

    Bool far_signOut = sDiffExps < 0 ? effSignB : a.sign;
    Bit#(sigWidth) far_sigLarger  = pack(truncate(sDiffExps < 0 ? b.sig : a.sig));
    Bit#(sigWidth) far_sigSmaller = pack(truncate(sDiffExps < 0 ? a.sig : b.sig));
    Bit#(TAdd#(sigWidth, 5)) far_mainAlignedSigSmaller = {far_sigSmaller, 5'b0} >> alignDist;
    Bit#(TDiv#(TAdd#(sigWidth, 2), 4)) far_reduced4SigSmaller = orReduceBy4({far_sigSmaller, 2'b0});
    Bit#(TDiv#(TAdd#(sigWidth, 2), 4)) far_roundExtraMask = 
      lowMask(pack(alignDist) >> 2, (sW + 5)/4, 0);
    Bit#(TAdd#(sigWidth, 2)) far_alignedSigSmaller_top = far_mainAlignedSigSmaller[sW + 4 : 3];
    Bit#(TAdd#(sigWidth, 3)) far_alignedSigSmaller =
        { far_alignedSigSmaller_top, pack(orR(far_mainAlignedSigSmaller[2 : 0]) || 
          orR(far_reduced4SigSmaller & far_roundExtraMask)) };
    Bool far_subMags = !eqSigns;
    Bit#(TAdd#(sigWidth, 4)) far_negAlignedSigSmaller = far_subMags ? 
        { 1, ~far_alignedSigSmaller } : zeroExtend(far_alignedSigSmaller);
    Bit#(TAdd#(sigWidth, 4)) far_sigSum = {1'b0, far_sigLarger, 3'b0} + far_negAlignedSigSmaller + zeroExtend(pack(far_subMags));
    Bit#(TAdd#(sigWidth, 3)) far_sigOut = far_subMags ? 
        truncate(far_sigSum) : truncate(far_sigSum>>1) | zeroExtend(far_sigSum[0]);
    
    Bool notSigNaN_invalidExc = a.isInf && b.isInf && !eqSigns;
    Bool notNaN_isInfOut = a.isInf || b.isInf;
    Bool addZeros = a.isZero && b.isZero;
    Bool notNaN_specialCase = notNaN_isInfOut || addZeros;
    Bool notNaN_isZeroOut = addZeros || (!notNaN_isInfOut && closeSubMags && close_totalCancellation);
    Bool notNaN_signOut =
        (eqSigns                      && a.sign          ) ||
        (a.isInf                   && a.sign          ) ||
        (b.isInf                   && effSignB           ) ||
        (notNaN_isZeroOut && !eqSigns && notEqSigns_signZero) ||
        (!notNaN_specialCase && closeSubMags && !close_totalCancellation && close_notTotalCancellation_signOut) ||
        (!notNaN_specialCase && !closeSubMags && far_signOut);
    Int#(TAdd#(2, expWidth)) common_sExpOut_long1 =
        closeSubMags || (sDiffExps < 0) ? b.sExp : a.sExp;
    Bit#(TAdd#(1, TLog#(sigWidth))) far_subMags1 = zeroExtend(pack(far_subMags));
    Bit#(TLog#(sigWidth)) common_sExpOut_long2 =
        closeSubMags ? close_nearNormDist : far_subMags1[valueOf(TLog#(sigWidth)) - 1 : 0];
    Int#(TMax#(TLog#(sigWidth), TAdd#(2, expWidth))) common_sExpOut_long =
        signExtend(common_sExpOut_long1) - unpack(zeroExtend(common_sExpOut_long2));
    Int#(TAdd#(2, expWidth)) common_sExpOut = unpack(pack(common_sExpOut_long)[eW + 1 : 0]); // i think this is safe?
    Bit#(TAdd#(3, sigWidth)) common_sigOut = closeSubMags ? close_sigOut : far_sigOut;

    Bool invalidExc = isSigNaNRawFloat(a) || isSigNaNRawFloat(b) || notSigNaN_invalidExc;
    RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
    rawOut.isInf = notNaN_isInfOut;
    rawOut.isZero = notNaN_isZeroOut;
    rawOut.sExp = common_sExpOut;
    rawOut.isNaN = a.isNaN || b.isNaN;
    rawOut.sign = notNaN_signOut;
    rawOut.sig = unpack(common_sigOut);
    return tuple2(invalidExc, rawOut);
  endfunction

  return f;
endfunction

typedef function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) _
  ( Bool subOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode,
    Bool detectTininess
  ) AddRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function AddRecFN#(expWidth, sigWidth) mkAddRecFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) f(
    Bool subOp,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode,
    Bool detectTininess
  );
    RawFloat#(expWidth, sigWidth) a_raw = rawFloatFromRecFN(a);
    RawFloat#(expWidth, sigWidth) b_raw = rawFloatFromRecFN(b);
    let addRes = mkAddRawFN(
      subOp,
      a_raw,
      b_raw,
      roundingMode
    );

    RoundRawFNToRecFN#(expWidth, sigWidth) roundRawFNToRecFN = mkRoundRawFNToRecFN(flRoundOpt_subnormAlwaysExact);
    let roundRes = roundRawFNToRecFN(
      tpl_1(addRes),
      False,
      tpl_2(addRes),
      roundingMode,
      pack(detectTininess)
    );
    
    return roundRes;
  endfunction

  return f;
endfunction