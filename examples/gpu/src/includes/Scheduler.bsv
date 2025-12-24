import Types::*;
import ProcTypes::*;
import FIFOF::*;
import Vector::*;
import GetPut::*;
import MergeTree::*;
import BRAM::*;
import BypassBRAM::*;

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
  Addr ipdom; // the PC of the immedite post-dominator
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

(* synthesize *)
module mkStacks(BRAM2Port#(Bit#(TAdd#(LogWarpNum, LogThreadNum)), StackEnt));
  let ram <- mkBypassBRAM;
  return ram;
endmodule

(* synthesize *)
module mkBarMasks(BRAM2Port#(Bit#(TLog#(BarNum)), Vector#(WarpNum, Bit#(ThreadNum))));
  let ram <- mkBypassBRAM;
  return ram;
endmodule

// TMC, WSPAWN, SPLIT, JOIN, PRED, BAR
(* synthesize *)
module mkScheduler(Scheduler);
  // a bitvector of what even/odd wids are assigned, number of allocated even/odd wids
  Vector#(2, Reg#(Bit#(TDiv#(WarpNum, 2)))) widAlloc <- replicateM(mkReg(pack(replicate(True))));
  Vector#(2, Reg#(Bit#(TLog#(TDiv#(TAdd#(WarpNum, 1), 2))))) widCount <- replicateM(mkReg(0)); // how many wids *were allocated*

  // warp divergence stack for intra-warp synchronization
  let stacks <- mkStacks;
  Reg#(Bit#(TSub#(TAdd#(LogWarpNum, LogThreadNum), 1))) stackInitPtr <- mkReg(0);
  Reg#(Bool) stackInit <- mkReg(False);
  Vector#(WarpNum, Reg#(Bit#(ThreadNum))) stackAlloc <- replicateM(mkReg(pack(replicate(True)))); // freelist

  // barrier management for inter-warp synchronization
  Reg#(Bit#(BarNum)) barDone <- mkReg(0);
  Vector#(BarNum, Reg#(Addr)) barPc <- replicateM(mkReg(0));
  let barMasks <- mkBarMasks;
  Vector#(BarNum, Reg#(Bit#(WarpNum))) barAlloc <- replicateM(mkReg(0));
  Vector#(BarNum, Reg#(Bit#(TLog#(WarpNum)))) barCount <- replicateM(mkReg(0)); // how many warps *left over* before synchronization
  Reg#(Bit#(TLog#(BarNum))) barDoneIdx <- mkRegU;
  Reg#(Bool) barDoneIdxValid <- mkReg(False);

  // requests
  FIFOF#(WspawnReq) wspawnReqs <- mkLFIFOF;
  Reg#(WspawnReq) curSpawn <- mkReg(unpack(0));
  FIFOF#(JoinReq) joinReqs <- mkLFIFOF;
  FIFOF#(SplitReq) splitReqs <- mkLFIFOF;
  FIFOF#(BarReq) barReqs <- mkLFIFOF;

  // done
  FIFOF#(void) done <- mkFIFOF;

  // response
  // 0: TMC/PRED, 1: WSPAWN, 2: CONV, 3: BAR
  MergeTree#(4, SchedResp) resps <- mkMergeTree;

  Bit#(LogWarpNum) upperCurSpawn = curSpawn.count[valueOf(LogWarpNum):1];

  // INIT
  (* fire_when_enabled *)
  rule init_stacks(!stackInit);
    stacks.portA.request.put(BRAMRequest {
      write: True, address: {stackInitPtr, 0}, datain: unpack(0), responseOnWrite: False
    });
    stacks.portB.request.put(BRAMRequest {
      write: True, address: {stackInitPtr, 1}, datain: unpack(0), responseOnWrite: False
    });
    let nextStackInitPtr = stackInitPtr + 1;
    stackInitPtr <= nextStackInitPtr;
    stackInit <= nextStackInitPtr == 0;
  endrule

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
  rule do_split(stackInit && !joinReqs.notEmpty);
    match SplitReq {warp: .warp, predMask: .predMask, top: .top} = splitReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    let allocMask = stackAlloc[wid];
    let ptr = pack(fromMaybe(?, findIndex(id, unpack(allocMask)))); // never fails
    Bool isDivergent = (predMask != 0) && (predMask != mask);
    if (isDivergent) begin // allocate new entry
      let ent = StackEnt{next: top, divMask: mask, convMask: 0, ipdom: ?};
      if (printDebug)
        $display(fshow("Split: ") + fshow(warp) + fshow(ent));
      stacks.portB.request.put(BRAMRequest {
        write: True, address: {wid, ptr}, datain: ent, responseOnWrite: False
      });
      stackAlloc[wid] <= allocMask & ~(1 << ptr);
      resps.iport[2].put(SchedResp{warp: warp, write: True, top: zeroExtend(pack(tagged Valid ptr))});
    end else begin
      resps.iport[2].put(SchedResp{warp: warp, write: False, top: 0});
    end
    splitReqs.deq;
  endrule

  // JOIN
  (* fire_when_enabled *)
  rule do_join(stackInit && joinReqs.notEmpty);
    match JoinReq {warp: .warp, top: .top} = joinReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    match StackEnt {
      next: .next, divMask: .divMask, convMask: .convMask, ipdom: .ipdom
    } <- stacks.portA.response.get;

    let allocMask = stackAlloc[wid];
    if (top matches tagged Valid .ptr) begin
      if (printDebug)
        $display(fshow("Join: ") + fshow(warp) + fshow(StackEnt{next: next, divMask: divMask, convMask: convMask, ipdom: ipdom}));
      let nextDivMask = divMask & ~mask;
      let nextConvMask = convMask | mask;
      let ent = StackEnt {next: next, divMask: nextDivMask, convMask: nextConvMask, ipdom: convMask == 0 ? pc : ipdom};
      stacks.portB.request.put(BRAMRequest {
        write: True, address: {wid, ptr}, datain: ent, responseOnWrite: False
      });
      if (nextDivMask == 0) begin
        if (pc == ipdom) begin
          stackAlloc[wid] <= allocMask | (1 << ptr);
          warp.mask = nextConvMask;
          resps.iport[2].put(SchedResp{warp: warp, write: True, top: zeroExtend(pack(next))});
        end else begin
          resps.iport[2].put(SchedResp{warp: warp, write: False, top: ?});
        end
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
    let masks <- barMasks.portA.response.get;
    if (barDone[b] == 0) begin
      masks[wid] = mask;

      let doUpdate = count == 1 || barCount[b] == 1;
      barDone <= barDone | (extend(pack(doUpdate)) << b);
      barPc[b] <= pc;

      barMasks.portB.request.put(BRAMRequest{
        write: True, address: b, datain: masks, responseOnWrite: False
      });
      barAlloc[b] <= barAlloc[b] | (1 << wid);
      barCount[b] <= barCount[b] == 0 ? truncate(count) - 1 : barCount[b] - 1;
      barReqs.deq;
    end
  endrule

  (* fire_when_enabled *)
  rule preload_barDoneIdx(!barReqs.notEmpty && !barDoneIdxValid);
    if (findIndex(id, unpack(barDone)) matches tagged Valid .b) begin
      barMasks.portB.request.put(BRAMRequest{
        write: False, address: pack(b), datain: ?, responseOnWrite: False
      });
      barDoneIdx <= pack(b);
      barDoneIdxValid <= True;
    end
  endrule

  (* fire_when_enabled *)
  rule process_bar(!barReqs.notEmpty && barDoneIdxValid);
    let b = barDoneIdx;
    let masks <- barMasks.portB.response.get;
    if (findIndex(id, unpack(barAlloc[b])) matches tagged Valid .wid) begin
      let warp = Warp {mask: masks[wid], wid: pack(wid), pc: barPc[b]};
      resps.iport[3].put(SchedResp {warp: warp, write: False, top: 0});
      barAlloc[b] <= barAlloc[b] & ~(1 << wid);
    end else begin
      barDone <= barDone & ~(1 << b);
      barDoneIdxValid <= False;
    end
  endrule

  method Action putSchedReq(SchedReq req) if (stackInit);
    if (printDebug)
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
      fnJOIN: begin
        let ptr = fromMaybe(?, top);
        stacks.portA.request.put(BRAMRequest {
          write: False, address: {warp.wid, ptr}, datain: ?, responseOnWrite: False
        });
        joinReqs.enq(joinReq);
      end
      fnBAR: begin
        barMasks.portA.request.put(BRAMRequest {
          write: False, address: truncate(v1), datain: ?, responseOnWrite: False
        });
        barReqs.enq(barReq);
      end
      fnPRED: wspawnReqs.enq(WspawnReq {warp: predWarp, count: 1, pc: 0});
    endcase
  endmethod

  method Action getDone = done.deq;

  method ActionValue#(SchedResp) getSchedResp;
    let resp = resps.first;
    resps.deq;
    return resp;
  endmethod
endmodule

