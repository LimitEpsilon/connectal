/*============================================================================

Copyright 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017 The Regents of the
University of California.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice,
    this list of conditions, and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions, and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

 3. Neither the name of the University nor the names of its contributors may
    be used to endorse or promote products derived from this software without
    specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS "AS IS", AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ARE
DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=============================================================================*/

import Vector::*;
import FloatingPoint::*;

// from common.scala
Bit#(3) round_near_even = 0;
Bit#(3) round_minMag = 1;
Bit#(3) round_min = 2;
Bit#(3) round_max = 3;
Bit#(3) round_near_maxMag = 4;
Bit#(3) round_odd = 6;

Bit#(1) tininess_beforeRounding = 0;
Bit#(1) tininess_afterRounding = 1;

Bit#(4) flRoundOpt_sigMSBitAlwaysZero = 1;
Bit#(4) flRoundOpt_subnormAlwaysExact = 2;
Bit#(4) flRoundOpt_neverUnderflows = 4;
Bit#(4) flRoundOpt_neverOverflows = 8;

Bit#(5) divSqrtOpt_twoBitsPerCycle = 16;

typedef struct {
  Bool isNaN;
  Bool isInf;
  Bool isZero;
  Bool sign;
  Int#(TAdd#(2, expWidth)) sExp;
  UInt#(TAdd#(1, sigWidth)) sig;
} RawFloat#(numeric type expWidth, numeric type sigWidth) deriving (Bits, Eq, FShow);

function Bool isSigNaNRawFloat(RawFloat#(eW, sW) in) = in.isNaN && !unpack(pack(in.sig)[valueOf(sW)-2]);

// from primitives.scala
// topBound, bottomBound < 2^wIn
// wOut = |topBound - bottomBound|
function Bit#(wOut) lowMask(Bit#(wIn) in, Integer topBound, Integer bottomBound);
  Integer numInVals = valueOf(TExp#(wIn));

  if (topBound < bottomBound) begin
    in = ~in; // in ← 2ʷ - 1 - in
    topBound = numInVals - 1 - topBound;
    bottomBound = numInVals - 1 - bottomBound;
  end

  Bit#(TExp#(wIn)) shift = ~(-1 << in); // ones in ++ zeroes (2ʷ - in)
  return shift[topBound-1 : bottomBound];
endfunction

function Tuple2#(Bool, Bit#(l)) countLeadingZeroes_(Integer offset, Integer level, Bit#(TExp#(l)) x);
  let logw = valueOf(l) - level - 1;
  if (logw < 0) begin
    return tuple2(unpack(x[offset]), 0);
  end else begin
    match {.upperValid, .upperCount} = countLeadingZeroes_(offset + (2 ** logw), level + 1, x);
    match {.lowerValid, .lowerCount} = countLeadingZeroes_(offset, level + 1, x);
    Bit#(l) mask = (1 << fromInteger(logw)) - 1;
    let count = (upperValid ? upperCount : lowerCount) & mask;
    count[logw] = pack(!upperValid);
    return tuple2(upperValid || lowerValid, count);
  end
endfunction

function Bit#(TLog#(n)) countLeadingZeroes(Bit#(n) x);
  Bit#(TMax#(TExp#(TLog#(n)), n)) y =
    zeroExtend(x) << fromInteger(valueOf(TExp#(TLog#(n))) - valueOf(n));
  return tpl_2(countLeadingZeroes_(0, 0, truncate(y)));
endfunction

// orReduce
function Bool orR(Bit#(w) in) = unpack(|in);

// andReduce
function Bool andR(Bit#(w) in) = unpack(&in);

function Bit#(TDiv#(w, d)) orReduceBy(Bit#(d) ghost, Bit#(w) in) // TDiv#(w, d) = ⌈w / d⌉
  provisos(Add#(1, _, d)); // you can't divide by zero
  Integer vd = valueOf(d);
  function Bit#(d) g(Integer i) = in[(i+1)*vd-1 : i*vd]; // gen
  return pack(map(orR, genWith(g)));
endfunction

function Bit#(TDiv#(w, 2)) orReduceBy2(Bit#(w) in) = orReduceBy(2'd0, in);
function Bit#(TDiv#(w, 4)) orReduceBy4(Bit#(w) in) = orReduceBy(4'd0, in);

// conversion functions
function RawFloat#(expWidth, sigWidth) rawFloatFromFN(Bit#(TAdd#(expWidth, sigWidth)) in)
  provisos (
    Add#(1, fractWidth, sigWidth),
    Add#(TLog#(fractWidth), _, TAdd#(1, expWidth))
  );

  Integer eW = valueOf(expWidth);
  Integer sW = valueOf(sigWidth);
  Bool sign = unpack(in[eW+sW-1]);
  Bit#(expWidth) expIn = in[eW+sW-2 : sW-1];
  Bit#(fractWidth) fractIn = in[sW-2 : 0];

  Bool isZeroExpIn = expIn == 0;
  Bool isZeroFractIn = fractIn == 0;

  Bit#(TAdd#(1, expWidth)) normDist = zeroExtend(countLeadingZeroes(fractIn));
  Bit#(fractWidth) subnormFract = (fractIn << normDist) << 1;
  Bit#(TAdd#(1, expWidth)) adjustedExp =
    (isZeroExpIn ? ~normDist : zeroExtend(expIn)) +
    ((1 << (eW - 1)) | (isZeroExpIn ? 2 : 1));

  Bool isZero = isZeroExpIn && isZeroFractIn;
  Bool isSpecial = adjustedExp[eW : eW-1] == 2'b11;

  return RawFloat {
    isNaN: isSpecial && !isZeroFractIn,
    isInf: isSpecial && isZeroFractIn,
    isZero: isZero,
    sign: sign,
    sExp: unpack(zeroExtend(adjustedExp)),
    sig: unpack({1'b0, pack(!isZero), isZeroExpIn ? subnormFract : fractIn})
  };
endfunction

function RawFloat#(expWidth, w) rawFloatFromIN(Bool signedIn, Bit#(w) in)
  provisos (Add#(1, TLog#(w), expWidth));

  Integer eW = valueOf(expWidth);
  Integer lW = valueOf(TLog#(w));
  Integer extIntWidth = 2 ** lW;

  let sign = signedIn && unpack(msb(in));
  Bit#(w) absIn = sign ? -in : in;
  Bit#(TMax#(TExp#(TLog#(w)), w)) extAbsIn = zeroExtend(absIn);
  Bit#(TLog#(w)) adjustedNormDist = countLeadingZeroes(extAbsIn)[lW-1 : 0];
  Bit#(w) sig = (extAbsIn << adjustedNormDist)[extIntWidth-1 : extIntWidth-valueOf(w)];

  return RawFloat {
    isNaN: False,
    isInf: False,
    isZero: unpack(~msb(sig)),
    sign: sign,
    sExp: unpack({3'b010, ~adjustedNormDist[eW-2 : 0]}),
    sig: unpack(zeroExtend(sig))
  };
endfunction

// invariant: no more than one of `isNaN`, `isInf`, `isZero` will be set
function RawFloat#(expWidth, sigWidth) rawFloatFromRecFN(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in)
  provisos (Add#(1, fractWidth, sigWidth));
  Integer eW = valueOf(expWidth);
  Integer sW = valueOf(sigWidth);

  Bit#(TAdd#(1, expWidth)) exp = in[eW+sW-1 : sW-1];
  Bool isZero = exp[eW : eW-2] == 3'b0;
  Bool isSpecial = exp[eW : eW-1] == 2'b11;

  return RawFloat {
    isNaN: isSpecial && unpack(exp[eW-2]),
    isInf: isSpecial && unpack(~exp[eW-2]),
    isZero: isZero,
    sign: unpack(in[eW+sW]),
    sExp: unpack(zeroExtend(exp)),
    sig: unpack({1'b0, pack(!isZero), in[sW-2 : 0]})
  };
endfunction

typedef function Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) _
  ( Bit#(TAdd#(expWidth, sigWidth)) in
  ) RecFNFromFN#(
  numeric type expWidth, numeric type sigWidth
);

function RecFNFromFN#(expWidth, sigWidth) recFNFromFN
  provisos (
    Add#(2, recExpWidth, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(TLog#(fractWidth), _, TAdd#(1, expWidth))
  );
  Integer eW = valueOf(expWidth);
  Integer sW = valueOf(sigWidth);

  function Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) f(Bit#(TAdd#(expWidth, sigWidth)) in);

  RawFloat#(expWidth, sigWidth) rawIn = rawFloatFromFN(in);
  let sExp = pack(rawIn.sExp);
  let sig = pack(rawIn.sig);

  Bit#(3) rawSpecial =
    (rawIn.isZero ? 3'b0 : sExp[eW : eW-2]) | (rawIn.isNaN ? 1 : 0);
  Bit#(recExpWidth) rawExp = sExp[eW-3 : 0];
  Bit#(fractWidth) rawSig = sig[sW-2 : 0];

  return {pack(rawIn.sign), rawSpecial, rawExp, rawSig};

  endfunction

  return f;
endfunction

typedef function Bit#(TAdd#(expWidth, sigWidth)) _
  ( Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in
  ) FNFromRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function FNFromRecFN#(expWidth, sigWidth) fNFromRecFN
  provisos (Add#(1, fractWidth, sigWidth));
  Integer eW = valueOf(expWidth);
  Integer sW = valueOf(sigWidth);
  Integer minNormExp = (2 ** (eW - 1)) + 2;

  function Bit#(TAdd#(expWidth, sigWidth)) f(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in);

  RawFloat#(expWidth, sigWidth) rawIn = rawFloatFromRecFN(in);

  Bool isSubnormal = rawIn.sExp < fromInteger(minNormExp);

  let sExp = pack(rawIn.sExp);
  let sig = pack(rawIn.sig);

  Bit#(TLog#(fractWidth)) denormShiftDist = 1 - sExp[valueOf(TLog#(fractWidth))-1 : 0];
  Bit#(fractWidth) denormFract = ((sig >> 1) >> denormShiftDist)[sW-2 : 0];

  Bit#(expWidth) expOut =
    (isSubnormal ? 0 : sExp[eW-1 : 0] - fromInteger(minNormExp - 1))
    | pack(replicate(rawIn.isNaN || rawIn.isInf));
  Bit#(fractWidth) fractOut =
    isSubnormal ? denormFract :
      (rawIn.isInf ? 0 : sig[sW-2 : 0]);

  return {pack(rawIn.sign), expOut, fractOut};

  endfunction

  return f;
endfunction

typedef function Bit#(10) _
  ( Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in
  ) ClassifyRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function ClassifyRecFN#(expWidth, sigWidth) classifyRecFN
  provisos (Add#(1, fractWidth, sigWidth));
  Integer eW = valueOf(expWidth);
  Integer sW = valueOf(sigWidth);
  Integer minNormExp = (2 ** (eW - 1)) + 2;

  function Bit#(10) f(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in);

  RawFloat#(expWidth, sigWidth) rawIn = rawFloatFromRecFN(in);
  Bool isSigNaN = isSigNaNRawFloat(rawIn);
  Bool isFiniteNonzero = !rawIn.isNaN && !rawIn.isInf && !rawIn.isZero;
  Bool isSubnormal = rawIn.sExp < fromInteger(minNormExp);

  return {
    pack(rawIn.isNaN && !isSigNaN),
    pack(isSigNaN),
    pack(!rawIn.sign && rawIn.isInf),
    pack(!rawIn.sign && isFiniteNonzero && !isSubnormal),
    pack(!rawIn.sign && isFiniteNonzero && isSubnormal),
    pack(!rawIn.sign && rawIn.isZero),
    pack(rawIn.sign && rawIn.isZero),
    pack(rawIn.sign && isFiniteNonzero && isSubnormal),
    pack(rawIn.sign && isFiniteNonzero && !isSubnormal),
    pack(rawIn.sign && rawIn.isInf)
  };

  endfunction
  return f;
endfunction

typedef
  Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception)
  RoundRes#(numeric type expWidth, numeric type sigWidth);

typedef function RoundRes#(outExpWidth, outSigWidth) _
  ( Bool invalidExc,
    Bool infiniteExc,
    RawFloat#(inExpWidth, inSigWidth) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  ) RoundAnyRawFNToRecFN#(
  numeric type inExpWidth, numeric type inSigWidth,
  numeric type outExpWidth, numeric type outSigWidth
);

// intended to be used as a module with type RoundAnyRawFNToRecFN
// (* noinline *) not possible because of the `options` parameter
function RoundAnyRawFNToRecFN#(inExpWidth, inSigWidth, outExpWidth, outSigWidth)
  mkRoundAnyRawFNToRecFN(Bit#(4) options)
  provisos (
    Add#(2, _1, outExpWidth),
    Add#(1, fractWidth, outSigWidth),
    Add#(1, _2, fractWidth)
  );

  let iEW = valueOf(inExpWidth);
  let iSW = valueOf(inSigWidth);
  let oEW = valueOf(outExpWidth);
  let oSW = valueOf(outSigWidth);

  let sigMSBitAlwaysZero = ((options & flRoundOpt_sigMSBitAlwaysZero) != 0);
  let effectiveInSigWidth = sigMSBitAlwaysZero ? iSW : iSW + 1;
  let neverUnderflows = (
    (options &
      (flRoundOpt_neverUnderflows | flRoundOpt_subnormAlwaysExact)
    ) != 0) ||
      (iEW < oEW);
  let neverOverflows =
    ((options & flRoundOpt_neverOverflows) != 0) ||
      (iEW < oEW);
  let outNaNExp = 7 * (2 ** (oEW - 2));
  let outInfExp = 6 * (2 ** (oEW - 2));
  let outMaxFiniteExp = outInfExp - 1;
  let outMinNormExp = (2 ** (oEW - 1)) + 2;
  let outMinNonzeroExp = outMinNormExp - oSW + 1;

  function RoundRes#(outExpWidth, outSigWidth) roundAnyRawFNToRecFN(
    Bool invalidExc,
    Bool infiniteExc,
    RawFloat#(inExpWidth, inSigWidth) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  );

  let roundingMode_near_even   = roundingMode == round_near_even;
  let roundingMode_minMag      = roundingMode == round_minMag;
  let roundingMode_min         = roundingMode == round_min;
  let roundingMode_max         = roundingMode == round_max;
  let roundingMode_near_maxMag = roundingMode == round_near_maxMag;
  let roundingMode_odd         = roundingMode == round_odd;

  let roundMagUp =
      (roundingMode_min && in.sign) || (roundingMode_max && ! in.sign);

  Int#(TMax#(outExpWidth, TAdd#(2, inExpWidth))) sExtendedExp = signExtend(in.sExp);
  Int#(TAdd#(1, TMax#(outExpWidth, TAdd#(2, inExpWidth)))) sAdjustedExp =
    signExtend(sExtendedExp) + fromInteger(2 ** oEW - 2 ** iEW);

  Bit#(TAdd#(3, outSigWidth)) adjustedSig;
  if (iSW <= oSW + 2) begin
    Bit#(TAdd#(1, TMax#(inSigWidth, TAdd#(2, outSigWidth)))) x =
      zeroExtend(pack(in.sig)) << (oSW + 2 - iSW);
    adjustedSig = x[oSW+2 : 0];
  end else begin
    Bit#(TAdd#(2, outSigWidth)) upper = pack(in.sig)[iSW : iSW-oSW-1];
    Bit#(TSub#(inSigWidth, TAdd#(1, outSigWidth))) lower = pack(in.sig)[iSW-oSW-2 : 0];
    adjustedSig = {upper, pack(orR(lower))};
  end

  Bool doShiftSigDown1 = unpack(sigMSBitAlwaysZero ? 0 : msb(adjustedSig));
  Bit#(TAdd#(1, outExpWidth)) common_expOut;
  Bit#(fractWidth) common_fractOut;
  Bool common_overflow, common_totalUnderflow, common_underflow, common_inexact;

  if (neverOverflows && neverUnderflows && effectiveInSigWidth <= oSW) begin
    common_expOut = pack(sAdjustedExp)[oEW : 0] + zeroExtend(pack(doShiftSigDown1));
    common_fractOut = doShiftSigDown1 ? adjustedSig[oSW+1 : 3] : adjustedSig[oSW : 2];
    common_overflow = False;
    common_totalUnderflow = False;
    common_underflow = False;
    common_inexact = False;
  end else begin
    Bit#(TAdd#(1, outExpWidth)) x = pack(sAdjustedExp)[oEW : 0];
    Bit#(TAdd#(3, outSigWidth)) roundMask = {(neverUnderflows ? 0
      : lowMask(x, outMinNormExp - oSW - 1, outMinNormExp)) |
      zeroExtend(pack(doShiftSigDown1)),
      2'b11
    };
    Bit#(TAdd#(3, outSigWidth)) shiftedRoundMask = roundMask >> 1;
    Bit#(TAdd#(3, outSigWidth)) roundPosMask = ~shiftedRoundMask & roundMask;
    Bool roundPosBit = orR(adjustedSig & roundPosMask);
    Bool anyRoundExtra = orR(adjustedSig & shiftedRoundMask);
    Bool anyRound = roundPosBit || anyRoundExtra;

    Bool roundIncr = ((roundingMode_near_even || roundingMode_near_maxMag) &&
      roundPosBit) || (roundMagUp && anyRound);
    Bit#(TAdd#(2, outSigWidth)) roundedSig = roundIncr ?
      (truncate((adjustedSig | roundMask) >> 2) + 1) &
      ~(roundingMode_near_even && roundPosBit && !anyRoundExtra ?
        truncate(roundMask >> 1) : 0) :
      truncate((adjustedSig & ~roundMask) >> 2) |
      (roundingMode_odd && anyRound ? truncate(roundPosMask >> 1) : 0);
    Bit#(2) roundedSigUpper = roundedSig[oSW+1 : oSW];
    Int#(TAdd#(2, TMax#(outExpWidth, TAdd#(2, inExpWidth)))) sRoundedExp =
      extend(sAdjustedExp) + unpack(zeroExtend(roundedSigUpper));
    Bool unboundedRange_roundPosBit =
      unpack(doShiftSigDown1 ? adjustedSig[2] : adjustedSig[1]);
    Bool unboundedRange_anyRound =
      doShiftSigDown1 && unpack(adjustedSig[2]) || orR(adjustedSig[1 : 0]);
    Bool unboundedRange_roundIncr =
      ((roundingMode_near_even || roundingMode_near_maxMag) && unboundedRange_roundPosBit) ||
      (roundMagUp && unboundedRange_anyRound);
    Bool roundCarry =
      unpack(doShiftSigDown1 ? roundedSig[oSW+1] : roundedSig[oSW]);

    common_expOut = pack(sRoundedExp)[oEW : 0];
    common_fractOut = doShiftSigDown1 ? roundedSig[oSW-1 : 1] : roundedSig[oSW-2 : 0];
    common_overflow = neverOverflows ? False : ((sRoundedExp >> (oEW - 1)) >= 3);
    common_totalUnderflow = neverUnderflows ? False : (sRoundedExp < fromInteger(outMinNonzeroExp));
    common_underflow = neverUnderflows ? False :
      common_totalUnderflow ||
      (anyRound && ((sAdjustedExp >> oEW) <= 0) &&
        unpack(doShiftSigDown1 ? roundMask[3] : roundMask[2]) &&
        !((detectTininess == tininess_afterRounding) &&
          !unpack(doShiftSigDown1 ? roundMask[4] : roundMask[3]) &&
          roundCarry && roundPosBit && unboundedRange_roundIncr));
    common_inexact = common_totalUnderflow || anyRound;
  end

  let isNaNOut = invalidExc || in.isNaN;
  let notNaN_isSpecialInfOut = infiniteExc || in.isInf;
  let commonCase = ! isNaNOut && ! notNaN_isSpecialInfOut && ! in.isZero;
  let overflow  = commonCase && common_overflow;
  let underflow = commonCase && common_underflow;
  let inexact = overflow || (commonCase && common_inexact);

  let overflow_roundMagUp =
      roundingMode_near_even || roundingMode_near_maxMag || roundMagUp;
  let pegMinNonzeroMagOut =
      commonCase && common_totalUnderflow && (roundMagUp || roundingMode_odd);
  let pegMaxFiniteMagOut = overflow && ! overflow_roundMagUp;
  let notNaN_isInfOut =
      notNaN_isSpecialInfOut || (overflow && overflow_roundMagUp);

  let signOut = isNaNOut ? False : in.sign;

  Bit#(TAdd#(1, outExpWidth)) expOut =
    (common_expOut
      & ~(in.isZero || common_totalUnderflow ? {3'b111, 0} : 0)
      & ~(pegMinNonzeroMagOut ? ~fromInteger(outMinNonzeroExp) : 0)
      & ~(pegMaxFiniteMagOut ? {3'b010, 0} : 0)
      & ~(notNaN_isInfOut ? {3'b001, 0} : 0))
    | (pegMinNonzeroMagOut ? fromInteger(outMinNonzeroExp) : 0)
    | (pegMaxFiniteMagOut ? fromInteger(outMaxFiniteExp) : 0)
    | (notNaN_isInfOut ? fromInteger(outInfExp) : 0)
    | (isNaNOut        ? fromInteger(outNaNExp) : 0);

  Bit#(fractWidth) fractOut =
    (isNaNOut || in.isZero || common_totalUnderflow ?
      (isNaNOut ? {1'b1, 0} : 0) :
        common_fractOut
    ) |
    pack(replicate(pegMaxFiniteMagOut));

  return tuple2(
    {pack(signOut), expOut, fractOut},
    Exception {
      invalid_op: invalidExc,
      divide_0: infiniteExc,
      overflow: overflow,
      underflow: underflow,
      inexact: inexact
    }
  );
  endfunction

  return roundAnyRawFNToRecFN;
endfunction

typedef RoundAnyRawFNToRecFN#(expWidth, TAdd#(2, sigWidth), expWidth, sigWidth)
  RoundRawFNToRecFN#(numeric type expWidth, numeric type sigWidth);

function RoundRawFNToRecFN#(expWidth, sigWidth) mkRoundRawFNToRecFN(Bit#(4) options)
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );
  RoundAnyRawFNToRecFN#(expWidth, TAdd#(2, sigWidth), expWidth, sigWidth) roundAnyRawFNToRecFN =
    mkRoundAnyRawFNToRecFN(options);
  return roundAnyRawFNToRecFN;
endfunction

typedef function RoundRes#(outExpWidth, outSigWidth) _
  ( Bit#(TAdd#(1, TAdd#(inExpWidth, inSigWidth))) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  ) RecFNToRecFN#(
  numeric type inExpWidth, numeric type inSigWidth,
  numeric type outExpWidth, numeric type outSigWidth
);

function RecFNToRecFN#(inExpWidth, inSigWidth, outExpWidth, outSigWidth) mkRecFNToRecFN
  provisos (
    Add#(1, _1, inSigWidth),
    Add#(2, _2, outExpWidth),
    Add#(1, fractWidth, outSigWidth),
    Add#(1, _3, fractWidth)
  );

  let iEW = valueOf(inExpWidth);
  let iSW = valueOf(inSigWidth);
  let oEW = valueOf(outExpWidth);
  let oSW = valueOf(outSigWidth);

  RoundAnyRawFNToRecFN#(inExpWidth, inSigWidth, outExpWidth, outSigWidth) roundAnyRawFNToRecFN =
    mkRoundAnyRawFNToRecFN(flRoundOpt_sigMSBitAlwaysZero);

  function RoundRes#(outExpWidth, outSigWidth) f(
    Bit#(TAdd#(1, TAdd#(inExpWidth, inSigWidth))) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  );
    RawFloat#(inExpWidth, inSigWidth) rawIn = rawFloatFromRecFN(in);
    Bool isNaN = isSigNaNRawFloat(rawIn);

    Bit#(TAdd#(
      TAdd#(1, TAdd#(inExpWidth, inSigWidth)),
      TMax#(0, TSub#(outSigWidth, inSigWidth)))) simple = {in, 0};
    return (iEW == oEW && iSW <= oSW) ?
      tuple2(simple[oEW+oSW : 0], unpack({pack(isNaN), 0})) :
      roundAnyRawFNToRecFN(isNaN, False, rawIn, roundingMode, detectTininess);
  endfunction

  return f;
endfunction

typedef function RoundRes#(expWidth, sigWidth) _
  ( Bit#(intWidth) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  ) INToRecFN#(
  numeric type intWidth, numeric type expWidth, numeric type sigWidth
);

function INToRecFN#(intWidth, expWidth, sigWidth) mkINToRecFN(Bool signedIn)
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  let iW = valueOf(intWidth);
  let eW = valueOf(expWidth);
  let sW = valueOf(sigWidth);

  RoundAnyRawFNToRecFN#(TAdd#(1, TLog#(intWidth)), intWidth, expWidth, sigWidth) roundAnyRawFNToRecFN =
    mkRoundAnyRawFNToRecFN(flRoundOpt_sigMSBitAlwaysZero | flRoundOpt_neverUnderflows);

  function RoundRes#(expWidth, sigWidth) f(
    Bit#(intWidth) in,
    Bit#(3) roundingMode,
    Bit#(1) detectTininess
  );
    RawFloat#(TAdd#(1, TLog#(intWidth)), intWidth) rawIn = rawFloatFromIN(signedIn, in);
    return roundAnyRawFNToRecFN(False, False, rawIn, roundingMode, detectTininess);
  endfunction

  return f;
endfunction

typedef function Tuple2#(Bit#(intWidth), Bit#(3)) _
  ( Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in,
    Bit#(3) roundingMode
  ) RecFNToIN#(
  numeric type expWidth, numeric type sigWidth, numeric type intWidth
);

function RecFNToIN#(expWidth, sigWidth, intWidth) mkRecFNToIN(Bool signedOut)
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth),
    Add#(2, _3, intWidth)
  );

  let iW = valueOf(intWidth);
  let eW = valueOf(expWidth);
  let sW = valueOf(sigWidth);
  let intExpWidth = valueOf(TLog#(intWidth));
  let boundedIntExpWidth = min(eW - 1, intExpWidth);

  function Tuple2#(Bit#(intWidth), Bit#(3)) f(
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) in,
    Bit#(3) roundingMode
  );

  RawFloat#(expWidth, sigWidth) rawIn = rawFloatFromRecFN(in);

  Bool magGeOne = unpack(pack(rawIn.sExp)[eW]);
  Bit#(expWidth) posExp = pack(rawIn.sExp)[eW-1 : 0];
  Bool magJustBelowOne = !magGeOne && andR(posExp);

  let roundingMode_near_even   = roundingMode == round_near_even;
  let roundingMode_minMag      = roundingMode == round_minMag;
  let roundingMode_min         = roundingMode == round_min;
  let roundingMode_max         = roundingMode == round_max;
  let roundingMode_near_maxMag = roundingMode == round_near_maxMag;
  let roundingMode_odd         = roundingMode == round_odd;

  /*------------------------------------------------------------------------
  | Assuming the input floating-point value is not a NaN, its magnitude is
  | at least 1, and it is not obviously so large as to lead to overflow,
  | convert its significand to fixed-point (i.e., with the binary point in a
  | fixed location).  For a non-NaN input with a magnitude less than 1, this
  | expression contrives to ensure that the integer bits of 'alignedSig'
  | will all be zeros.
  *------------------------------------------------------------------------*/
  Bit#(sigWidth) shiftedSigUpper = {pack(magGeOne), pack(rawIn.sig)[sW-2 : 0]};
  Bit#(TMin#(TSub#(expWidth, 1), TLog#(intWidth))) shiftedSigShamt =
    magGeOne ? pack(rawIn.sExp)[boundedIntExpWidth-1 : 0] : 0;
  Bit#(TAdd#(intWidth, sigWidth)) shiftedSig = zeroExtend(shiftedSigUpper) << shiftedSigShamt;

  Bit#(TSub#(fractWidth, 1)) shiftedSigLower = shiftedSig[sW-3 : 0];
  Bit#(TAdd#(intWidth, 2)) alignedSig =
    {truncate(shiftedSig >> (sW - 2)), pack(orR(shiftedSigLower))};
  Bit#(intWidth) unroundedInt = alignedSig[iW+1 : 2];

  let common_inexact = magGeOne ? orR(alignedSig[1 : 0]) : !rawIn.isZero;
  let roundIncr_near_even =
    (magGeOne       && (andR(alignedSig[2 : 1]) || andR(alignedSig[1 : 0]))) ||
    (magJustBelowOne && orR(alignedSig[1 : 0]));
  let roundIncr_near_maxMag = (magGeOne && unpack(alignedSig[1])) || magJustBelowOne;
  let roundIncr =
    (roundingMode_near_even   && roundIncr_near_even  ) ||
    (roundingMode_near_maxMag && roundIncr_near_maxMag) ||
    ((roundingMode_min || roundingMode_odd) &&
         (rawIn.sign && common_inexact)) ||
    (roundingMode_max && (!rawIn.sign && common_inexact));
  let complUnroundedInt = rawIn.sign ? ~unroundedInt : unroundedInt;
  let roundedInt =
    (roundIncr != rawIn.sign ? complUnroundedInt + 1 : complUnroundedInt)
    | zeroExtend({1'b0, pack(roundingMode_odd && common_inexact)});

  let magGeOne_overflow = False;
  if (iW < 2 ** eW) magGeOne_overflow = posExp >= fromInteger(iW);
  let magGeOne_atOverflowEdge = False;
  if (iW - 1 < 2 ** eW) magGeOne_atOverflowEdge = posExp == fromInteger(iW - 1);
  let magGeOne_subOverflowEdge = False;
  if (iW - 2 < 2 ** eW) magGeOne_subOverflowEdge = posExp == fromInteger(iW - 2);

  Bit#(TSub#(intWidth, 2)) roundCarryBut2_ = truncate(unroundedInt);
  let roundCarryBut2 = andR(roundCarryBut2_) && roundIncr;
  let common_overflow =
    (magGeOne ?
      magGeOne_overflow ||
        (signedOut ?
          (rawIn.sign ?
            magGeOne_atOverflowEdge &&
              (unpack(unroundedInt[iW-2]) || orR(roundCarryBut2_) || roundIncr) :
            magGeOne_atOverflowEdge ||
              (magGeOne_subOverflowEdge && roundCarryBut2)
          ) :
          rawIn.sign ||
            (magGeOne_atOverflowEdge &&
              unpack(unroundedInt[iW-2]) && roundCarryBut2)
        ) :
      !signedOut && rawIn.sign && roundIncr
    );

  //------------------------------------------------------------------------
  //------------------------------------------------------------------------
  Bit#(3) exn = ?;
  let invalidExc = rawIn.isNaN || rawIn.isInf;
  exn[2] = pack(invalidExc);
  exn[1] = pack(!invalidExc && common_overflow);
  exn[0] = pack(!invalidExc && !common_overflow && common_inexact);

  let excSign = !rawIn.isNaN && rawIn.sign;
  Bit#(intWidth) excOut =
    (signedOut == excSign ? (1 << (iW - 1)) : 0)
    | (!excSign ? ~(1 << (iW - 1)) : 0);

  return tuple2((invalidExc || common_overflow ? excOut : roundedInt), exn);
  endfunction

  return f;
endfunction

typedef struct {
  Bool lt;
  Bool eq;
  Bool gt;
  Exception fflags;
} CompareRes deriving (Bits, Eq, FShow);

typedef function CompareRes _
  ( Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bool signaling
  ) CompareRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function CompareRecFN#(expWidth, sigWidth) mkCompareRecFN
  provisos (
    Add#(1, fractWidth, sigWidth)
  );

  function CompareRes f(
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bool signaling
  );
    RawFloat#(expWidth, sigWidth) rawA = rawFloatFromRecFN(a);
    RawFloat#(expWidth, sigWidth) rawB = rawFloatFromRecFN(b);

    let ordered = ! rawA.isNaN && ! rawB.isNaN;
    let bothInfs  = rawA.isInf  && rawB.isInf;
    let bothZeros = rawA.isZero && rawB.isZero;
    let eqExps = (rawA.sExp == rawB.sExp);
    let common_ltMags =
        (rawA.sExp < rawB.sExp) || (eqExps && (rawA.sig < rawB.sig));
    let common_eqMags = eqExps && (rawA.sig == rawB.sig);

    let ordered_lt =
        ! bothZeros &&
            ((rawA.sign && ! rawB.sign) ||
                 (! bothInfs &&
                      ((rawA.sign && ! common_ltMags && ! common_eqMags) ||
                           (! rawB.sign && common_ltMags))));
    let ordered_eq =
        bothZeros || ((rawA.sign == rawB.sign) && (bothInfs || common_eqMags));

    Exception exc = unpack(0);
    exc.invalid_op =
        isSigNaNRawFloat(rawA) || isSigNaNRawFloat(rawB) ||
            (signaling && ! ordered);
    return CompareRes {
      lt: ordered && ordered_lt,
      eq: ordered && ordered_eq,
      gt: ordered && !ordered_lt && !ordered_eq,
      fflags: exc
    };
  endfunction

  return f;
endfunction

