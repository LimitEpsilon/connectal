import Vector::*;
import Fifo::*;

import Types::*;
import RFile::*;

// A completion stays in a source-local queue until the destination bank can
// accept it.  In particular, the ready signal of a register-file bank never
// reaches an execution unit combinationally.
typedef Tuple2#(RFWrReq#(ThreadNum), Bit#(LocalWarpNum)) CompletionPayload;

typedef struct {
  Bit#(LogBankNum) bank;
  CompletionPayload payload;
} CompletionPacket deriving (Bits, Eq, FShow);

typedef 6 CompletionSourceNum;
typedef UInt#(TLog#(CompletionSourceNum)) CompletionSourceId;

interface CompletionOutput;
  method Bool notEmpty;
  method CompletionPayload first;
  method Action deq;
endinterface

interface CompletionNetwork;
  method Action putEX(CompletionPacket packet);
  method Action putMUL(CompletionPacket packet);
  method Action putDIV(CompletionPacket packet);
  method Action putFPU(CompletionPacket packet);
  method Action putMEM(CompletionPacket packet);
  method Action putCSR(CompletionPacket packet);
  interface Vector#(BankNum, CompletionOutput) egress;
endinterface

// Keeping these FIFOs behind module boundaries gives the placer an explicit
// register boundary at each producer and consumer.  Conflict-free FIFOs let a
// source and the switch, or the switch and a consumer, transfer every cycle
// once the pipeline is occupied.  Their notFull signals depend only on local
// occupancy; they do not bypass a downstream dequeue.
(* synthesize *)
module mkCompletionSource(Fifo#(2, CompletionPacket));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkCompletionDestination(Fifo#(2, CompletionPayload));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkCompletionNetwork(CompletionNetwork);
  Vector#(CompletionSourceNum, Fifo#(2, CompletionPacket)) sources <-
    replicateM(mkCompletionSource);
  Vector#(BankNum, Fifo#(2, CompletionPayload)) destinations <-
    replicateM(mkCompletionDestination);

  // This is the same epoch arbitration policy used by MergeTree, now applied
  // only to narrow source tags.  The selected wide payload crosses exactly
  // one registered switch boundary before reaching its bank.
  Vector#(BankNum, Reg#(Bool)) cur <- replicateM(mkReg(True));
  Vector#(BankNum, Vector#(CompletionSourceNum, Reg#(Bool))) epochs <-
    replicateM(replicateM(mkReg(True)));

  (* fire_when_enabled *)
  rule route_completions;
    Vector#(CompletionSourceNum, Bool) occupied = newVector;
    Vector#(CompletionSourceNum, CompletionPacket) heads = newVector;
    for (Integer s = 0; s < valueOf(CompletionSourceNum); s = s + 1) begin
      occupied[s] = sources[s].notEmpty;
      heads[s] = sources[s].first;
    end

    Vector#(BankNum, Maybe#(CompletionSourceId)) choices =
      replicate(tagged Invalid);

    for (Integer b = 0; b < valueOf(BankNum); b = b + 1) begin
      Vector#(CompletionSourceNum, Bool) validT = newVector;
      Vector#(CompletionSourceNum, Bool) validF = newVector;
      for (Integer s = 0; s < valueOf(CompletionSourceNum); s = s + 1) begin
        Bool routedHere = occupied[s] && heads[s].bank == fromInteger(b);
        validT[s] = routedHere && epochs[b][s];
        validF[s] = routedHere && !epochs[b][s];
      end

      let idxT = findIndex(id, validT);
      let idxF = findIndex(id, validF);
      Bool rdyT = any(id, validT);
      Bool rdyF = any(id, validF);
      Bool rdy = rdyT || rdyF;
      CompletionSourceId idx = case (tuple2(idxT, idxF)) matches
        {tagged Valid .iT, tagged Valid .iF}: cur[b] ? iT : iF;
        {tagged Valid .iT, tagged Invalid}: iT;
        {tagged Invalid, tagged Valid .iF}: iF;
        default: ?;
      endcase;

      if (destinations[b].notFull && rdy) begin
        Bool e = rdyT && (!rdyF || cur[b]);
        choices[b] = tagged Valid idx;
        destinations[b].enq(heads[idx].payload);
        epochs[b][idx] <= !e;
        cur[b] <= e;
      end
    end

    // A packet encodes exactly one bank, so at most one choice names any
    // source.  Calling each dequeue method once also makes that invariant
    // explicit to the Bluespec scheduler.
    for (Integer s = 0; s < valueOf(CompletionSourceNum); s = s + 1) begin
      Bool selected = False;
      for (Integer b = 0; b < valueOf(BankNum); b = b + 1)
        if (choices[b] matches tagged Valid .chosen)
          selected = selected || chosen == fromInteger(s);
      if (selected) sources[s].deq;
    end
  endrule

  Vector#(BankNum, CompletionOutput) outputIfc = newVector;
  for (Integer b = 0; b < valueOf(BankNum); b = b + 1)
    outputIfc[b] =
      interface CompletionOutput;
        method Bool notEmpty = destinations[b].notEmpty;
        method CompletionPayload first if (destinations[b].notEmpty) =
          destinations[b].first;
        method Action deq if (destinations[b].notEmpty) =
          destinations[b].deq;
      endinterface;

  method Action putEX(packet)  = sources[0].enq(packet);
  method Action putMUL(packet) = sources[1].enq(packet);
  method Action putDIV(packet) = sources[2].enq(packet);
  method Action putFPU(packet) = sources[3].enq(packet);
  method Action putMEM(packet) = sources[4].enq(packet);
  method Action putCSR(packet) = sources[5].enq(packet);
  interface egress = outputIfc;
endmodule
