import Vector::*;
import FloatingPoint::*;
import HardFloat::*;

// Mirrors HardFloat Chisel: MulFullRawFN → MulRawFN → MulRecFN (see hardfloat MulRecFN.scala).

typedef function Tuple2#(Bool, RawFloat#(expWidth, TSub#(TMul#(2, sigWidth), 1))) _
  ( RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b
  ) MulFullRawFN#(
  numeric type expWidth, numeric type sigWidth
);

function MulFullRawFN#(expWidth, sigWidth) mkMulFullRawFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  function Tuple2#(Bool, RawFloat#(expWidth, TSub#(TMul#(2, sigWidth), 1))) f(
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b
  );
    Integer eW = valueOf(expWidth);
    Integer sW = valueOf(sigWidth);

    Bool notSigNaN_invalidExc = (a.isInf && b.isZero) || (a.isZero && b.isInf);
    Bool notNaN_isInfOut = a.isInf || b.isInf;
    Bool notNaN_isZeroOut = a.isZero || b.isZero;
    Bool notNaN_signOut = a.sign != b.sign;
    Int#(TAdd#(2, expWidth)) common_sExpOut = a.sExp + b.sExp - (1<<eW);
    Integer sigBits = valueOf(TAdd#(1, sigWidth));
    Bit#(TAdd#(2, TMul#(2, sigWidth))) fullProd =
      pack(a.sig)[sigBits-1 : 0] * pack(b.sig)[sigBits-1 : 0];
    Bit#(TMul#(2, sigWidth)) common_sigOut = truncate(fullProd);
    RawFloat#(expWidth, TSub#(TMul#(2, sigWidth), 1)) rawOut;
    Bool invalidExc = isSigNaNRawFloat(a) || isSigNaNRawFloat(b) || notSigNaN_invalidExc;
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

typedef function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) _
  ( RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b
  ) MulRawFN#(
  numeric type expWidth, numeric type sigWidth
);

function MulRawFN#(expWidth, sigWidth) mkMulRawFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  function Tuple2#(Bool, RawFloat#(expWidth, TAdd#(2, sigWidth))) f(
    RawFloat#(expWidth, sigWidth) a,
    RawFloat#(expWidth, sigWidth) b
  );
    Integer sW = valueOf(sigWidth);

    MulFullRawFN#(expWidth, sigWidth) mulFullRaw = mkMulFullRawFN;
    match {.invalidExc, .fullRaw} = mulFullRaw(a, b);
    Bit#(TMul#(2, sigWidth)) sig = pack(fullRaw.sig);
    Bit#(TAdd#(2, sigWidth)) high = sig[2*sW-1 : sW-2];
    Bit#(TSub#(sigWidth, 2)) lowBits = sig[sW-3 : 0];
    Bool sticky = orR(lowBits);
    RawFloat#(expWidth, TAdd#(2, sigWidth)) rawOut;
    rawOut.isInf = fullRaw.isInf;
    rawOut.isZero = fullRaw.isZero;
    rawOut.sExp = fullRaw.sExp;
    rawOut.isNaN = fullRaw.isNaN;
    rawOut.sign = fullRaw.sign;
    Bit#(TAdd#(1, TAdd#(2, sigWidth))) mulSig = {high, pack(sticky)};
    rawOut.sig = unpack(mulSig);
    return tuple2(invalidExc, rawOut);
  endfunction

  return f;
endfunction

typedef function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) _
  ( Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode,
    Bool detectTininess
  ) MulRecFN#(
  numeric type expWidth, numeric type sigWidth
);

function MulRecFN#(expWidth, sigWidth) mkMulRecFN
  provisos (
    Add#(2, _1, expWidth),
    Add#(1, fractWidth, sigWidth),
    Add#(1, _2, fractWidth)
  );

  function Tuple2#(Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))), Exception) f(
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) a,
    Bit#(TAdd#(1, TAdd#(expWidth, sigWidth))) b,
    Bit#(3) roundingMode,
    Bool detectTininess
  );
    RawFloat#(expWidth, sigWidth) a_raw = rawFloatFromRecFN(a);
    RawFloat#(expWidth, sigWidth) b_raw = rawFloatFromRecFN(b);
    MulRawFN#(expWidth, sigWidth) mulRawFn = mkMulRawFN;
    match {.invalidExc, .rawOut} = mulRawFn(a_raw, b_raw);
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