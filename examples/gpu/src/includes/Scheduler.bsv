import Types::*;
import ProcTypes::*;
import FIFOF::*;
import Vector::*;
import GetPut::*;
import MergeTree::*;
import BRAM::*;
import BypassBRAM::*;
import Count::*;

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
  Bit#(LogWarpNum) count;
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
  Addr fp; // FP at the moment JOIN is issued (from SchedReq.v1); used as a frame identifier
} JoinReq deriving (Bits, Eq, FShow);

typedef struct {
  Warp warp;
  Maybe#(StackPtr) top;
  Addr ipdom;
} SplitReq deriving (Bits, Eq, FShow);

typedef struct {
  Maybe#(StackPtr) next;
  Bit#(ThreadNum) divMask; // mask of threads that are still divergent
  Bit#(ThreadNum) convMask; // mask of threads that joined here (the "resident")
  Addr ipdom; // the PC of the immediate post-dominator
  Addr fp; // frame identifier — set by the FIRST joiner (when convMask was 0).
           // See IntraWarpDivergence.md for the rationale and kick-out semantics.
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
module mkBars(BRAM1Port#(Bit#(TAdd#(LogBarNum, LogWarpNum)), Warp));
  let ram <- mkBRAM1Server(defaultValue);
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
  let bars <- mkBars;
  Reg#(Maybe#(Bit#(LogBarNum))) barDone <- mkReg(tagged Invalid);
  Vector#(BarNum, Reg#(Bit#(WarpNum))) barAlloc <- replicateM(mkReg(0));
  Vector#(BarNum, Reg#(Bit#(TLog#(WarpNum)))) barCount <- replicateM(mkReg(0)); // how many warps *left over* before synchronization

  // requests
  FIFOF#(Warp) tmcReqs <- mkLFIFOF;
  FIFOF#(WspawnReq) wspawnReqs <- mkLFIFOF;
  Reg#(WspawnReq) curSpawn <- mkReg(WspawnReq{count: 1, pc: 0});
  FIFOF#(JoinReq) joinReqs <- mkLFIFOF;
  FIFOF#(SplitReq) splitReqs <- mkLFIFOF;
  FIFOF#(BarReq) barReqs <- mkFIFOF;

  // done
  FIFOF#(void) done <- mkFIFOF;

  // response
  // 0: TMC/PRED/WSPAWN, 1: new warps from WSPAWN, 2: SPLIT/JOIN, 3: BAR
  MergeTree#(4, SchedResp) resps <- mkMergeTree;

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

  // TMC, PRED, WSPAWN
  (* fire_when_enabled *)
  rule do_tmc(tmcReqs.notEmpty);
    let warp <- toGet(tmcReqs).get;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    Bit#(TLog#(TDiv#(WarpNum, 2))) upperWid = wid[valueOf(LogWarpNum)-1:1];
    let alloc = widAlloc[wid[0]];
    let countNeg = widCount[~wid[0]];
    let count = widCount[wid[0]];
    if (mask != 0)
      resps.iport[0].put(SchedResp {warp: warp, write: False, top: 0});
    else begin
      widAlloc[wid[0]] <= alloc | (1 << upperWid); // restore alloc
      widCount[wid[0]] <= count == 0 ? 0 : count - 1; // restore count
      if (countNeg == 0 && count == 1) done.enq(?);
    end
  endrule

  // new warps from WSPAWN
  (* fire_when_enabled *)
  rule do_wspawn(!tmcReqs.notEmpty && curSpawn.count != 1);
    let evenWid = countLSB(widAlloc[0]);
    let oddWid = countLSB(widAlloc[1]);
    match WspawnReq {count: .count, pc: .pc} = curSpawn;
    let nextCurSpawn = WspawnReq {count: count - 1, pc: pc};
    if (widCount[1] < widCount[0]) begin // allocate odd wid
      widCount[1] <= widCount[1] + 1;
      widAlloc[1] <= widAlloc[1] & ~(1 << oddWid);
      let newWarp = Warp {mask: 1, wid: {pack(oddWid), 1'b1}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end else if (widAlloc[0] != 0) begin // allocate even wid
      widCount[0] <= widCount[0] + 1;
      widAlloc[0] <= widAlloc[0] & ~(1 << evenWid);
      let newWarp = Warp {mask: 1, wid: {pack(evenWid), 1'b0}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end // else, no free warps
  endrule

  (* fire_when_enabled *)
  rule process_wspawn(curSpawn.count == 1); // curSpawn is invalid, fill it up
    curSpawn <= wspawnReqs.first;
    wspawnReqs.deq;
  endrule

  // SPLIT
  (* fire_when_enabled *)
  rule do_split(stackInit && !joinReqs.notEmpty);
    match SplitReq {warp: .warp, top: .top, ipdom: .ipdom} = splitReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    let allocMask = stackAlloc[wid];
    let ptr = pack(countLSB(allocMask)); // never fails
    Bool isDivergent = countIf(id, unpack(mask)) != 1;
    if (isDivergent) begin // allocate new entry
      let ent = StackEnt{next: top, divMask: mask, convMask: 0, ipdom: ipdom, fp: 0};
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
    match JoinReq {warp: .warp, top: .top, fp: .fp_now} = joinReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    match StackEnt {
      next: .next, divMask: .divMask, convMask: .convMask, ipdom: .ipdom, fp: .top_fp
    } <- stacks.portA.response.get;
    let allocMask = stackAlloc[wid];

    // Mirrors src/Scheduler/SchedulerImpl.v do_join_syn one-for-one:
    // factor every conditional field into a let-binding, build ONE
    // write_ent / release_resp / passthrough_resp shared across all
    // branches, and gate the action with `entry_match`.
    Bool top_valid = isValid(top);
    StackPtr ptr = fromMaybe(?, top);  // unused when !top_valid
    let ptr_set = (1 << ptr);
    let newAllocFreed = allocMask | ptr_set;
    let top_val_next = zeroExtend(pack(next));
    let top_val_current = zeroExtend(pack(top));

    Bool pc_eq_ipdom = (pc == ipdom);
    Bool convMaskZero = (convMask == 0);
    Bool fp_eq = (fp_now == top_fp);
    Bool fp_lt = (fp_now < top_fp);
    Bool firstJoinerOrEq = convMaskZero || fp_eq;
    let nextDivMask = divMask & ~mask;
    let nextConvMask = convMask | mask;
    Bool nextDivIsZero = (nextDivMask == 0);

    // Shared StackEnt write-back. Real-join (firstJoinerOrEq) uses
    // (nextDivMask, nextConvMask, effective_fp); kick-out (`>`) uses
    // ((divMask|convMask)&~mask, mask, fp_now). See IntraWarpDivergence.md §6.
    Addr effective_fp = convMaskZero ? fp_now : top_fp;
    Bit#(ThreadNum) kick_divMask = (divMask | convMask) & ~mask;
    Bit#(ThreadNum) write_divMask = firstJoinerOrEq ? nextDivMask : kick_divMask;
    Bit#(ThreadNum) write_convMask = firstJoinerOrEq ? nextConvMask : mask;
    Addr write_fp = firstJoinerOrEq ? effective_fp : fp_now;
    let write_ent = StackEnt {
      next: next, divMask: write_divMask, convMask: write_convMask,
      ipdom: ipdom, fp: write_fp
    };

    // Shared release SchedResp. Real-join pop releases the merged warp
    // at the joiner's pc with mask=nextConvMask, write=True, top=next
    // (the merged warp's stack pointer drops one frame). Kick-out releases
    // the wrongly-installed resident at pc=ipdom with mask=convMask,
    // write=False (the resident's Core-side top register is PRESERVED:
    // they reached the wrong-JOIN with top=Valid(ptr) of this same slot,
    // and we want them to come back here on their next outer-JOIN attempt
    // to complete convergence — overwriting top to `next` would lose track
    // of this entry, particularly fatal when `next` is Invalid because
    // S_outer is the bottommost frame). See IntraWarpDivergence.md §5/§6.
    Bit#(ThreadNum) release_mask = firstJoinerOrEq ? nextConvMask : convMask;
    Addr release_pc = firstJoinerOrEq ? pc : ipdom;
    Warp release_warp = Warp { wid: wid, pc: release_pc, mask: release_mask };
    let release_resp = SchedResp {
      warp: release_warp, write: firstJoinerOrEq, top: top_val_next
    };

    // Shared passthrough SchedResp. Covers top.Invalid, pc != ipdom, and
    // the fp_lt spurious case. top is unobservable to the Core (write=False)
    // but we mirror the Coq's `zeroExtend(pack(top))` exactly.
    let passthrough_resp = SchedResp {
      warp: warp, write: False, top: top_val_current
    };

    Bool entry_match = top_valid && pc_eq_ipdom;
    if (entry_match) begin
      if (printDebug)
        $display(fshow("Join: ") + fshow(warp) + fshow(StackEnt{
          next: next, divMask: divMask, convMask: convMask, ipdom: ipdom, fp: top_fp
        }));
      if (firstJoinerOrEq) begin
        stacks.portB.request.put(BRAMRequest {
          write: True, address: {wid, ptr}, datain: write_ent, responseOnWrite: False
        });
        if (nextDivIsZero) begin
          // All threads converged: pop the entry, release the merged warp.
          stackAlloc[wid] <= newAllocFreed;
          resps.iport[2].put(release_resp);
        end
        // else: halt — joiner is the (new or additional) resident.
      end else begin
        if (fp_lt) begin
          // Spurious: top entry belongs to a shallower frame than the joiner.
          resps.iport[2].put(passthrough_resp);
        end else begin
          // fp_now > top_fp: kick out the wrongly-installed resident and
          // directly install the current joiner in the same cycle. Always
          // halts: under the contract, nextDivMask after this update is
          // provably non-zero (divMask|convMask is preserved as the full
          // original SPLIT mask; the joiner's mask is a strict subset).
          resps.iport[2].put(release_resp);
          stacks.portB.request.put(BRAMRequest {
            write: True, address: {wid, ptr}, datain: write_ent, responseOnWrite: False
          });
        end
      end
    end else begin
      resps.iport[2].put(passthrough_resp);
    end
    joinReqs.deq;
  endrule

  // BAR arrival
  // well-formedness: all barrier requests must have count ≠ 1
  (* fire_when_enabled *)
  rule do_bar(!isValid(barDone));
    match BarReq {warp: .warp, barId: .b, count: .count} = barReqs.first;

    bars.portA.request.put(BRAMRequest {
      write: True, address: {b, warp.wid}, datain: warp, responseOnWrite: False
    });

    let c = barCount[b];
    let isDone = c == 1;
    let nextCount = (c == 0 ? truncate(count) : c) - 1;

    barDone <= isDone ? tagged Valid b : tagged Invalid;
    barAlloc[b] <= barAlloc[b] | (1 << warp.wid);
    barCount[b] <= nextCount;
    barReqs.deq;
  endrule

  // BAR release
  (* fire_when_enabled *)
  rule process_bar(isValid(barDone));
    let b = fromMaybe(?, barDone);
    if (findIndex(id, unpack(barAlloc[b])) matches tagged Valid .wid) begin
      bars.portA.request.put(BRAMRequest {
        write: False, address: {b, pack(wid)}, datain: ?, responseOnWrite: False
      });
      barAlloc[b] <= barAlloc[b] & ~(1 << wid);
    end else begin
      barDone <= tagged Invalid;
    end
  endrule

  (* fire_when_enabled *)
  rule finish_bar;
    let warp <- bars.portA.response.get;
    resps.iport[3].put(SchedResp {warp: warp, write: False, top: 0});
  endrule

  method Action putSchedReq(SchedReq req) if (stackInit);
    if (printDebug)
      $display(fshow(req));
    match SchedReq {warp: .warp, f: .f, v1: .v1, v2: .v2} = req;
    Bit#(ThreadNum) predMask = warp.mask & truncate(v1);
    Bit#(ThreadNum) restoreMask = truncate(v2);
    Maybe#(StackPtr) top = unpack(truncate(v2));

    let wspawnReq = WspawnReq {count: truncate(v1), pc: v2};
    // JOIN reuses v1 as the warp's current SP (frame identifier). The caller
    // must place SP into v1 for fnJOIN; other ops use v1 for their own purposes.
    let joinReq = JoinReq {warp: warp, top: top, fp: v1};
    let splitReq = SplitReq {warp: warp, top: top, ipdom: v1};
    let barReq = BarReq {warp: warp, barId: truncate(v1), count: truncate(v2)};
    let predWarp = Warp {wid: warp.wid, pc: warp.pc, mask: predMask == 0 ? restoreMask : predMask};
    let tmcWarp = Warp {wid: warp.wid, pc: warp.pc, mask: truncate(v1)};

    case (f)
      fnTMC: tmcReqs.enq(tmcWarp);
      fnWSPAWN: begin
        tmcReqs.enq(warp);
        wspawnReqs.enq(wspawnReq);
      end
      fnSPLIT: splitReqs.enq(splitReq);
      fnJOIN: begin
        let ptr = fromMaybe(?, top);
        stacks.portA.request.put(BRAMRequest {
          write: False, address: {warp.wid, ptr}, datain: ?, responseOnWrite: False
        });
        joinReqs.enq(joinReq);
      end
      fnBAR: barReqs.enq(barReq);
      fnPRED: tmcReqs.enq(predWarp);
    endcase
  endmethod

  method Action getDone = done.deq;

  method ActionValue#(SchedResp) getSchedResp;
    let resp = resps.first;
    resps.deq;
    return resp;
  endmethod
endmodule

// TMC, WSPAWN, SPLIT, JOIN, PRED, BAR
(* synthesize *)
module mkOldScheduler(Scheduler);
  // a bitvector of what even/odd wids are assigned, number of allocated even/odd wids
  Vector#(2, Reg#(Bit#(TDiv#(WarpNum, 2)))) widAlloc <- replicateM(mkReg(pack(replicate(True))));
  Vector#(2, Reg#(Bit#(TLog#(TDiv#(TAdd#(WarpNum, 1), 2))))) widCount <- replicateM(mkReg(0)); // how many wids *were allocated*

  // warp divergence stack for intra-warp synchronization
  let stacks <- mkStacks;
  Reg#(Bit#(TSub#(TAdd#(LogWarpNum, LogThreadNum), 1))) stackInitPtr <- mkReg(0);
  Reg#(Bool) stackInit <- mkReg(False);
  Vector#(WarpNum, Reg#(Bit#(ThreadNum))) stackAlloc <- replicateM(mkReg(pack(replicate(True)))); // freelist

  // barrier management for inter-warp synchronization
  let bars <- mkBars;
  Reg#(Maybe#(Bit#(LogBarNum))) barDone <- mkReg(tagged Invalid);
  Vector#(BarNum, Reg#(Bit#(WarpNum))) barAlloc <- replicateM(mkReg(0));
  Vector#(BarNum, Reg#(Bit#(TLog#(WarpNum)))) barCount <- replicateM(mkReg(0)); // how many warps *left over* before synchronization

  // requests
  FIFOF#(Warp) tmcReqs <- mkLFIFOF;
  FIFOF#(WspawnReq) wspawnReqs <- mkLFIFOF;
  Reg#(WspawnReq) curSpawn <- mkReg(WspawnReq{count: 1, pc: 0});
  FIFOF#(JoinReq) joinReqs <- mkLFIFOF;
  FIFOF#(SplitReq) splitReqs <- mkLFIFOF;
  FIFOF#(BarReq) barReqs <- mkFIFOF;

  // done
  FIFOF#(void) done <- mkFIFOF;

  // response
  // 0: TMC/PRED/WSPAWN, 1: new warps from WSPAWN, 2: SPLIT/JOIN, 3: BAR
  MergeTree#(4, SchedResp) resps <- mkMergeTree;

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

  // TMC, PRED, WSPAWN
  (* fire_when_enabled *)
  rule do_tmc(tmcReqs.notEmpty);
    let warp <- toGet(tmcReqs).get;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    Bit#(TLog#(TDiv#(WarpNum, 2))) upperWid = wid[valueOf(LogWarpNum)-1:1];
    let alloc = widAlloc[wid[0]];
    let countNeg = widCount[~wid[0]];
    let count = widCount[wid[0]];
    if (mask != 0)
      resps.iport[0].put(SchedResp {warp: warp, write: False, top: 0});
    else begin
      widAlloc[wid[0]] <= alloc | (1 << upperWid); // restore alloc
      widCount[wid[0]] <= count == 0 ? 0 : count - 1; // restore count
      if (countNeg == 0 && count == 1) done.enq(?);
    end
  endrule

  // new warps from WSPAWN
  (* fire_when_enabled *)
  rule do_wspawn(!tmcReqs.notEmpty && curSpawn.count != 1);
    let evenWid = countLSB(widAlloc[0]);
    let oddWid = countLSB(widAlloc[1]);
    match WspawnReq {count: .count, pc: .pc} = curSpawn;
    let nextCurSpawn = WspawnReq {count: count - 1, pc: pc};
    if (widCount[1] < widCount[0]) begin // allocate odd wid
      widCount[1] <= widCount[1] + 1;
      widAlloc[1] <= widAlloc[1] & ~(1 << oddWid);
      let newWarp = Warp {mask: 1, wid: {pack(oddWid), 1'b1}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end else if (widAlloc[0] != 0) begin // allocate even wid
      widCount[0] <= widCount[0] + 1;
      widAlloc[0] <= widAlloc[0] & ~(1 << evenWid);
      let newWarp = Warp {mask: 1, wid: {pack(evenWid), 1'b0}, pc: pc};
      resps.iport[1].put(SchedResp {warp: newWarp, write: True, top: 0});
      curSpawn <= nextCurSpawn;
    end // else, no free warps
  endrule

  (* fire_when_enabled *)
  rule process_wspawn(curSpawn.count == 1); // curSpawn is invalid, fill it up
    curSpawn <= wspawnReqs.first;
    wspawnReqs.deq;
  endrule

  // SPLIT
  (* fire_when_enabled *)
  rule do_split(stackInit && !joinReqs.notEmpty);
    match SplitReq {warp: .warp, top: .top, ipdom: .ipdom} = splitReqs.first;
    match Warp {wid: .wid, pc: .pc, mask: .mask} = warp;
    let allocMask = stackAlloc[wid];
    let ptr = pack(countLSB(allocMask)); // never fails
    let predMask = warp.mask & truncate(ipdom);
    Bool isDivergent = (predMask != 0) && (predMask != mask);
    if (isDivergent) begin // allocate new entry
      let ent = StackEnt{next: top, divMask: mask, convMask: 0, ipdom: ipdom, fp: 0};
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
    let nextDivMask = divMask & ~mask;
    let nextConvMask = convMask | mask;
    let noUpdate = convMask != 0 && pc != ipdom; // this is a join from a non-divergent subwarp that split off from this entry
    let ent = StackEnt {
      next: next,
      divMask: noUpdate ? divMask : nextDivMask,
      convMask: noUpdate ? convMask : nextConvMask,
      ipdom: convMask == 0 ? pc : ipdom
    };
    if (top matches tagged Valid .ptr) begin
      if (printDebug)
        $display(fshow("Join: ") + fshow(warp) + fshow(StackEnt{next: next, divMask: divMask, convMask: convMask, ipdom: ipdom}));
      stacks.portB.request.put(BRAMRequest {
        write: True, address: {wid, ptr}, datain: ent, responseOnWrite: False
      });
      if (noUpdate) begin
        resps.iport[2].put(SchedResp{warp: warp, write: False, top: 0});
      end else if (nextDivMask == 0) begin
        stackAlloc[wid] <= allocMask | (1 << ptr);
        warp.mask = nextConvMask;
        resps.iport[2].put(SchedResp{warp: warp, write: True, top: zeroExtend(pack(next))});
      end
    end else begin
      resps.iport[2].put(SchedResp{warp: warp, write: False, top: 0});
    end
    joinReqs.deq;
  endrule

  // BAR arrival
  // well-formedness: all barrier requests must have count ≠ 1
  (* fire_when_enabled *)
  rule do_bar(!isValid(barDone));
    match BarReq {warp: .warp, barId: .b, count: .count} = barReqs.first;

    bars.portA.request.put(BRAMRequest {
      write: True, address: {b, warp.wid}, datain: warp, responseOnWrite: False
    });

    let c = barCount[b];
    let isDone = c == 1;
    let nextCount = (c == 0 ? truncate(count) : c) - 1;

    barDone <= isDone ? tagged Valid b : tagged Invalid;
    barAlloc[b] <= barAlloc[b] | (1 << warp.wid);
    barCount[b] <= nextCount;
    barReqs.deq;
  endrule

  // BAR release
  (* fire_when_enabled *)
  rule process_bar(isValid(barDone));
    let b = fromMaybe(?, barDone);
    if (findIndex(id, unpack(barAlloc[b])) matches tagged Valid .wid) begin
      bars.portA.request.put(BRAMRequest {
        write: False, address: {b, pack(wid)}, datain: ?, responseOnWrite: False
      });
      barAlloc[b] <= barAlloc[b] & ~(1 << wid);
    end else begin
      barDone <= tagged Invalid;
    end
  endrule

  (* fire_when_enabled *)
  rule finish_bar;
    let warp <- bars.portA.response.get;
    resps.iport[3].put(SchedResp {warp: warp, write: False, top: 0});
  endrule

  method Action putSchedReq(SchedReq req) if (stackInit);
    if (printDebug)
      $display(fshow(req));
    match SchedReq {warp: .warp, f: .f, v1: .v1, v2: .v2} = req;
    Bit#(ThreadNum) predMask = warp.mask & truncate(v1);
    Bit#(ThreadNum) restoreMask = truncate(v2);
    Maybe#(StackPtr) top = unpack(truncate(v2));

    let wspawnReq = WspawnReq {count: truncate(v1), pc: v2}; // if v1 = 2^LogWarpNum, count will be 0
    let joinReq = JoinReq {warp: warp, top: top, fp: v1};
    let splitReq = SplitReq {warp: warp, top: top, ipdom: v1};
    let barReq = BarReq {warp: warp, barId: truncate(v1), count: truncate(v2)};
    let predWarp = Warp {wid: warp.wid, pc: warp.pc, mask: predMask == 0 ? restoreMask : predMask};
    let tmcWarp = Warp {wid: warp.wid, pc: warp.pc, mask: truncate(v1)};

    case (f)
      fnTMC: tmcReqs.enq(tmcWarp);
      fnWSPAWN: begin
        tmcReqs.enq(warp);
        wspawnReqs.enq(wspawnReq);
      end
      fnSPLIT: splitReqs.enq(splitReq);
      fnJOIN: begin
        let ptr = fromMaybe(?, top);
        stacks.portA.request.put(BRAMRequest {
          write: False, address: {warp.wid, ptr}, datain: ?, responseOnWrite: False
        });
        joinReqs.enq(joinReq);
      end
      fnBAR: barReqs.enq(barReq);
      fnPRED: tmcReqs.enq(predWarp);
    endcase
  endmethod

  method Action getDone = done.deq;

  method ActionValue#(SchedResp) getSchedResp;
    let resp = resps.first;
    resps.deq;
    return resp;
  endmethod
endmodule
