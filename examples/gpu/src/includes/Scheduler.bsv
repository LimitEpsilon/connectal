import Types::*;
import ProcTypes::*;
import FIFOF::*;
import Vector::*;
import GetPut::*;
import MergeTree::*;

typedef TDiv#(WarpNum, 2) BarNum; // at least 2 warps need to converge on a barrier
typedef TLog#(BarNum) LogBarNum;
typedef Bit#(LogThreadNum) StackPtr;

// use x0 to store the top of the stack
typedef struct {
  Warp warp;
  Bit#(3) f; // funct3
  Data v1;
  Data v2;
} SchedReq deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Bit#(TAdd#(LogWarpNum, 1)) count;
  Addr pc;
} WspawnReq deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Bit#(LogBarNum) barId;
  Bit#(TAdd#(LogWarpNum, 1)) count;
} BarReq deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Maybe#(StackPtr) top;
} JoinReq deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Bit#(ThreadNum) predMask;
  Maybe#(StackPtr) top;
} SplitReq deriving (Bits, Eq, FShow);

// the PC to continue after divergence is the pc from the JOIN request
// so no need to keep it in the stack
typedef struct {
  Maybe#(StackPtr) next;
  Bit#(ThreadNum) divMask; // mask of threads that are still divergent
  Bit#(ThreadNum) convMask; // mask of threads that converged
} StackEnt deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Bool write;
  Data top; // pointer to the top of the stack
} SchedResp deriving (Bits, Eq, FShow);

interface Scheduler;
  method Action putSchedReq(SchedReq req);
  method Action getDone;
  method ActionValue#(SchedResp) getSchedResp;
endinterface

// TMC, WSPAWN, SPLIT, JOIN, PRED, BAR
(* synthesize *)
module mkScheduler(Scheduler);
  // a bitvector of what even/odd wids are assigned, number of allocated even/odd wids
  Vector#(2, Reg#(Bit#(TDiv#(WarpNum, 2)))) widAlloc <- replicateM(mkReg(pack(replicate(True))));
  Vector#(2, Reg#(Bit#(TLog#(TDiv#(TAdd#(WarpNum, 1), 2))))) widCount <- replicateM(mkReg(0)); // how many wids *were allocated*

  // warp divergence stack for intra-warp synchronization
  Vector#(WarpNum, Reg#(Vector#(ThreadNum, StackEnt))) stacks <- replicateM(mkReg(unpack(0)));
  Vector#(WarpNum, Reg#(Bit#(ThreadNum))) stackAlloc <- replicateM(mkReg(pack(replicate(True)))); // freelist

  // barrier management for inter-warp synchronization
  Vector#(BarNum, Reg#(Bool)) barDone <- replicateM(mkReg(False));
  Vector#(BarNum, Reg#(Addr)) barPc <- replicateM(mkReg(0));
  Vector#(BarNum, Reg#(Vector#(WarpNum, Bit#(ThreadNum)))) barMasks <- replicateM(mkReg(replicate(0))); // might make more sense to make into BRAM
  Vector#(BarNum, Reg#(Bit#(WarpNum))) barAlloc <- replicateM(mkReg(0));
  Vector#(BarNum, Reg#(Bit#(TLog#(WarpNum)))) barCount <- replicateM(mkReg(0)); // how many warps *left over* before synchronization

  // requests
  FIFOF#(WspawnReq) wspawnReqs <- mkLFIFOF;
  Reg#(WspawnReq) curSpawn <- mkReg(unpack(0));
  FIFOF#(JoinReq) joinReqs <- mkLFIFOF;
  FIFOF#(SplitReq) splitReqs <- mkLFIFOF;
  FIFOF#(BarReq) barReqs <- mkLFIFOF;

  // done
  FIFOF#(void) done <- mkFIFOF;

`ifdef SIMULATION
  // debugging
  Reg#(Bool) doReport[2] <- mkCReg(2, False);
`endif

  // response
  // 0: TMC/PRED, 1: WSPAWN, 2: CONV, 3: BAR
  MergeTree#(4, SchedResp) resps <- mkMergeTree;

  Bit#(LogWarpNum) upperCurSpawn = curSpawn.count[valueOf(LogWarpNum):1];

`ifdef SIMULATION
  (* fire_when_enabled, no_implicit_conditions *)
  rule report(doReport[0]);
    Integer i, j;
    for (i = 0; i < 2; i = i + 1) begin
      $display("widCount[%0d]: %d", i, widCount[i]);
      $display("widAlloc[%0d]: %b", i, widAlloc[i]);
    end
    for (i = 0; i < valueOf(WarpNum); i = i + 1) begin
      $display("stackAlloc[%0d]: %b", i, stackAlloc[i]);
      for (j = 0; j < valueOf(ThreadNum); j = j + 1)
        $display(
          $format("curStacks[%0d][%0d] = next: ", i, j) +
          fshow(stacks[i][j].next) +
          $format("divMask: %b, convMask: %b", stacks[i][j].divMask, stacks[i][j].convMask)
        );
    end

    doReport[0] <= False;
  endrule
`endif

  // WSPAWN
  (* fire_when_enabled *)
  rule do_wspawn(upperCurSpawn != 0);
    let evenWid = findIndex(id, unpack(widAlloc[0]));
    let oddWid = findIndex(id, unpack(widAlloc[1]));
    let ewid = fromMaybe(?, evenWid);
    let owid = fromMaybe(?, oddWid);
    match WspawnReq {warp: .warp, count: .count, pc: .pc} = curSpawn;
    let nextCurSpawn = WspawnReq {warp: warp, count: count - 1, pc: pc};
    if (widCount[1] < widCount[0]) begin // allocate odd wid
      widCount[1] <= widCount[1] + 1;
      widAlloc[1] <= widAlloc[1] & ~(1 << owid);
      let newWarp = Warp {mask: 1, wid: {pack(owid), 1'b1}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end else if (isValid(evenWid)) begin // allocate even wid
      widCount[0] <= widCount[0] + 1;
      widAlloc[0] <= widAlloc[0] & ~(1 << ewid);
      let newWarp = Warp {mask: 1, wid: {pack(ewid), 1'b0}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end // else, no free warps
  endrule

  (* fire_when_enabled *)
  rule process_spawn(upperCurSpawn == 0);
    match Warp {wid: .wid, pc: .pc, mask: .mask} = curSpawn.warp;
    Bit#(TLog#(TDiv#(WarpNum, 2))) upperWid = wid[valueOf(LogWarpNum)-1:1];
    let alloc = widAlloc[wid[0]];
    let countNeg = widCount[~wid[0]];
    let count = widCount[wid[0]];
    if (unpack(curSpawn.count[0])) begin // valid
      if (mask != 0)
        resps.iport[1].put(SchedResp {warp: curSpawn.warp, write: False, top: 0});
      else begin
        widAlloc[wid[0]] <= alloc | (1 << upperWid); // restore alloc
        widCount[wid[0]] <= count == 0 ? 0 : count - 1; // restore count
        if (countNeg == 0 && count == 1) done.enq(?);
      end
    end

    if (wspawnReqs.notEmpty) begin
      curSpawn <= wspawnReqs.first;
      wspawnReqs.deq;
    end else begin
      curSpawn <= unpack(0); // turn off
    end
  endrule

  // SPLIT
  (* fire_when_enabled *)
  rule do_split(!joinReqs.notEmpty);
    match SplitReq {warp: .warp, predMask: .predMask, top: .top} = splitReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    let allocMask = stackAlloc[wid];
    let ptr = fromMaybe(?, findIndex(id, unpack(allocMask))); // never fails
    Bool isDivergent = (predMask != 0) && (predMask != mask);
    if (isDivergent) begin // allocate new entry
      let ents = stacks[wid];
      ents[ptr] = StackEnt{next: top, divMask: mask, convMask: 0};
      stacks[wid] <= ents;
      stackAlloc[wid] <= allocMask & ~(1 << ptr);
      resps.iport[2].put(SchedResp{warp: warp, write: True, top: zeroExtend(pack(tagged Valid ptr))});
    end else begin
      resps.iport[2].put(SchedResp{warp: warp, write: False, top: 0});
    end
    splitReqs.deq;
  endrule

  // JOIN
  (* fire_when_enabled *)
  rule do_join(joinReqs.notEmpty);
    match JoinReq {warp: .warp, top: .top} = joinReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    let allocMask = stackAlloc[wid];
    if (top matches tagged Valid .ptr) begin
      let ents = stacks[wid]; // preload this from BRAM when we enq to joinReqs
      match StackEnt {next: .next, divMask: .divMask, convMask: .convMask} = ents[ptr];
      let nextDivMask = divMask & ~mask;
      let nextConvMask = convMask | mask;
      if (nextDivMask == 0) begin
        stackAlloc[wid] <= allocMask | (1 << ptr);
        let joined = Warp {wid: wid, pc: pc, mask: nextConvMask};
        resps.iport[2].put(SchedResp{warp: joined, write: True, top: zeroExtend(pack(next))});
      end else begin
        ents[ptr] = StackEnt {next: next, divMask: nextDivMask, convMask: nextConvMask};
        stacks[wid] <= ents;
      end
    end else begin
      resps.iport[2].put(SchedResp{warp: warp, write: False, top: 0});
    end
    joinReqs.deq;
  endrule

  // BAR
  (* fire_when_enabled *)
  rule do_bar(barReqs.notEmpty);
    match BarReq {warp: .warp, barId: .b, count: .count} = barReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    if (!barDone[b]) begin
      let masks = barMasks[b]; // preload this from BRAM when we enq to barReqs
      masks[wid] = mask;

      barDone[b] <= count == 1 || barCount[b] == 1;
      barPc[b] <= pc;
      barMasks[b] <= masks;
      barAlloc[b] <= barAlloc[b] | (1 << wid);
      barCount[b] <= barCount[b] == 0 ? truncate(count) - 1 : barCount[b] - 1;
      barReqs.deq;
    end
  endrule

  (* fire_when_enabled *)
  rule process_bar(!barReqs.notEmpty);
    function t read(Reg#(t) b) = b;
    if (findIndex(read, barDone) matches tagged Valid .b) begin
      if (findIndex(id, unpack(barAlloc[b])) matches tagged Valid .wid) begin
        let warp = Warp {mask: barMasks[b][wid], wid: pack(wid), pc: barPc[b]};
        resps.iport[3].put(SchedResp {warp: warp, write: False, top: 0});
        barAlloc[b] <= barAlloc[b] & ~(1 << wid);
      end else
        barDone[b] <= False;
    end
  endrule

  method Action putSchedReq(SchedReq req);
    $display(fshow(req));
    match SchedReq {warp: .warp, f: .f, v1: .v1, v2: .v2} = req;
    Bit#(ThreadNum) predMask = warp.mask & truncate(v1);
    Bit#(ThreadNum) restoreMask = truncate(v2);
    Maybe#(StackPtr) top = unpack(truncate(v2));

    let wspawnReq = WspawnReq {warp: warp, count: truncate(v1), pc: v2};
    let joinReq = JoinReq {warp: warp, top: top};
    let splitReq = SplitReq {warp: warp, predMask: predMask, top: top};
    let barReq = BarReq {warp: warp, barId: truncate(v1), count: truncate(v2)};
    let predWarp = Warp {wid: warp.wid, pc: warp.pc, mask: predMask == 0 ? restoreMask : predMask};
    let tmcWarp = Warp {wid: warp.wid, pc: warp.pc, mask: truncate(v1)};

    case (f)
      fnTMC: wspawnReqs.enq(WspawnReq {warp: tmcWarp, count: 1, pc: 0});
      fnWSPAWN: wspawnReqs.enq(wspawnReq);
      fnSPLIT: splitReqs.enq(splitReq);
      fnJOIN: joinReqs.enq(joinReq);
      fnBAR: barReqs.enq(barReq);
      fnPRED: wspawnReqs.enq(WspawnReq {warp: predWarp, count: 1, pc: 0});
    endcase
  endmethod

  method Action getDone = done.deq;

  method ActionValue#(SchedResp) getSchedResp;
`ifdef SIMULATION
    // doReport[1] <= True;
`endif
    let resp = resps.first;
    resps.deq;
    return resp;
  endmethod
endmodule

