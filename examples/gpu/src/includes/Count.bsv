// alternative implementations of findIndex

function Tuple2#(Bool, Bit#(l)) countLSB_(Integer offset, Integer level, Bit#(TExp#(l)) x);
  let logw = valueOf(l) - level - 1;
  if (logw < 0) begin
    return tuple2(unpack(x[offset]), 0);
  end else begin
    match {.upperValid, .upperCount} = countLSB_(offset + (2 ** logw), level + 1, x);
    match {.lowerValid, .lowerCount} = countLSB_(offset, level + 1, x);
    Bit#(l) mask = (1 << fromInteger(logw)) - 1;
    let count = (lowerValid ? lowerCount : upperCount) & mask;
    count[logw] = pack(!lowerValid);
    return tuple2(upperValid || lowerValid, count);
  end
endfunction

// Same as fromMaybe(?, findIndex(id, unpack(x)))
function UInt#(TLog#(n)) countLSB(Bit#(n) x);
  Bit#(TMax#(TExp#(TLog#(n)), n)) y = zeroExtend(x);
  return unpack(tpl_2(countLSB_(0, 0, truncate(y))));
endfunction

function Tuple2#(Bool, Bit#(l)) countMSB_(Integer offset, Integer level, Bit#(TExp#(l)) x);
  let logw = valueOf(l) - level - 1;
  if (logw < 0) begin
    return tuple2(unpack(x[offset]), 0);
  end else begin
    match {.upperValid, .upperCount} = countMSB_(offset + (2 ** logw), level + 1, x);
    match {.lowerValid, .lowerCount} = countMSB_(offset, level + 1, x);
    Bit#(l) mask = (1 << fromInteger(logw)) - 1;
    let count = (upperValid ? upperCount : lowerCount) & mask;
    count[logw] = pack(!upperValid);
    return tuple2(upperValid || lowerValid, count);
  end
endfunction

// Same as fromMaybe(?, findIndex(id, reverse(unpack(x))))
function UInt#(TLog#(n)) countMSB(Bit#(n) x);
  Bit#(TMax#(TExp#(TLog#(n)), n)) y =
    zeroExtend(x) << fromInteger(valueOf(TExp#(TLog#(n))) - valueOf(n));
  return unpack(tpl_2(countMSB_(0, 0, truncate(y))));
endfunction

