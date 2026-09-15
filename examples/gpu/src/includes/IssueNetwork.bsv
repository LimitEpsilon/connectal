import Vector::*;
import GetPut::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import Exec::*;
import Fpu::*;
import Scheduler::*;
import CsrFile::*;

typedef Tuple2#(AluReq#(ThreadNum), EXCont) EXIssue;
typedef Tuple2#(MulReq#(ThreadNum), WBCont) MULIssue;
typedef Tuple2#(DivReq#(ThreadNum), WBCont) DIVIssue;
typedef Tuple2#(FpuReq#(ThreadNum), WBCont) FPUIssue;
typedef Tuple2#(BruReq#(ThreadNum), BRCont) BRIssue;
typedef Tuple2#(CsrReq#(ThreadNum), WBCont) CSRIssue;

// A bank issues at most one instruction per cycle.  The tag selects a local
// virtual output queue; independent queues avoid cross-destination blocking.
typedef union tagged {
  EXIssue   ToEX;
  SchedReq  ToSCHED;
  MULIssue  ToMUL;
  DIVIssue  ToDIV;
  FPUIssue  ToFPU;
  BRIssue   ToBR;
  CSRIssue  ToCSR;
} IssuePacket deriving (Bits, Eq, FShow);

typedef 7 IssueDestinationNum;
typedef UInt#(TLog#(BankNum)) IssueSourceId;

interface IssueOutput#(type t);
  method Bool notEmpty;
  method t first;
  method Action deq;
endinterface

interface IssueNetwork;
  interface Vector#(BankNum, Put#(IssuePacket)) ingress;
  interface IssueOutput#(EXIssue) ex;
  interface IssueOutput#(SchedReq) sched;
  interface IssueOutput#(MULIssue) mul;
  interface IssueOutput#(DIVIssue) divide;
  interface IssueOutput#(FPUIssue) fpu;
  interface IssueOutput#(BRIssue) bru;
  interface IssueOutput#(CSRIssue) csr;
  method Bool csrPending;
endinterface

function Tuple2#(Maybe#(IssueSourceId), Bool) chooseIssueSource(
    Vector#(BankNum, Bool) candidates,
    Vector#(BankNum, Bool) epochs,
    Bool cur);
  Vector#(BankNum, Bool) validT = newVector;
  Vector#(BankNum, Bool) validF = newVector;
  for (Integer s = 0; s < valueOf(BankNum); s = s + 1) begin
    validT[s] = candidates[s] && epochs[s];
    validF[s] = candidates[s] && !epochs[s];
  end

  let idxT = findIndex(id, validT);
  let idxF = findIndex(id, validF);
  Bool rdyT = any(id, validT);
  Bool rdyF = any(id, validF);
  Bool e = rdyT && (!rdyF || cur);
  Maybe#(IssueSourceId) idx = case (tuple2(idxT, idxF)) matches
    {tagged Valid .iT, tagged Valid .iF}: tagged Valid (cur ? iT : iF);
    {tagged Valid .iT, tagged Invalid}: tagged Valid iT;
    {tagged Invalid, tagged Valid .iF}: tagged Valid iF;
    default: tagged Invalid;
  endcase;
  return tuple2(idx, e);
endfunction

(* synthesize *)
module mkEXIssueDestination(Fifo#(2, EXIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkSchedIssueDestination(Fifo#(2, SchedReq));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkMULIssueDestination(Fifo#(2, MULIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkDIVIssueDestination(Fifo#(2, DIVIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkFPUIssueDestination(Fifo#(2, FPUIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkBRIssueDestination(Fifo#(2, BRIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

(* synthesize *)
module mkCSRIssueDestination(Fifo#(2, CSRIssue));
  let q <- mkCFFifo(True, False);
  return q;
endmodule

// One instance is placed with each RF bank.  Accessors are deliberately
// unguarded; the central switch consults the corresponding notEmpty bit before
// selecting a payload.  This keeps all downstream readiness out of put.
interface IssueBankSource;
  method Action put(IssuePacket packet);
  method Bool exNotEmpty;
  method EXIssue exFirst;
  method Action exDeq;
  method Bool schedNotEmpty;
  method SchedReq schedFirst;
  method Action schedDeq;
  method Bool mulNotEmpty;
  method MULIssue mulFirst;
  method Action mulDeq;
  method Bool divNotEmpty;
  method DIVIssue divFirst;
  method Action divDeq;
  method Bool fpuNotEmpty;
  method FPUIssue fpuFirst;
  method Action fpuDeq;
  method Bool brNotEmpty;
  method BRIssue brFirst;
  method Action brDeq;
  method Bool csrNotEmpty;
  method CSRIssue csrFirst;
  method Action csrDeq;
endinterface

(* synthesize *)
module mkIssueBankSource(IssueBankSource);
  Fifo#(2, EXIssue) exQ <- mkCFFifo(True, False);
  Fifo#(2, SchedReq) schedQ <- mkCFFifo(True, False);
  Fifo#(2, MULIssue) mulQ <- mkCFFifo(True, False);
  Fifo#(2, DIVIssue) divQ <- mkCFFifo(True, False);
  Fifo#(2, FPUIssue) fpuQ <- mkCFFifo(True, False);
  Fifo#(2, BRIssue) brQ <- mkCFFifo(True, False);
  Fifo#(2, CSRIssue) csrQ <- mkCFFifo(True, False);

  method Action put(packet);
    case (packet) matches
      tagged ToEX .payload: exQ.enq(payload);
      tagged ToSCHED .payload: schedQ.enq(payload);
      tagged ToMUL .payload: mulQ.enq(payload);
      tagged ToDIV .payload: divQ.enq(payload);
      tagged ToFPU .payload: fpuQ.enq(payload);
      tagged ToBR .payload: brQ.enq(payload);
      tagged ToCSR .payload: csrQ.enq(payload);
    endcase
  endmethod
  method Bool exNotEmpty = exQ.notEmpty;
  method EXIssue exFirst = exQ.first;
  method Action exDeq = exQ.deq;
  method Bool schedNotEmpty = schedQ.notEmpty;
  method SchedReq schedFirst = schedQ.first;
  method Action schedDeq = schedQ.deq;
  method Bool mulNotEmpty = mulQ.notEmpty;
  method MULIssue mulFirst = mulQ.first;
  method Action mulDeq = mulQ.deq;
  method Bool divNotEmpty = divQ.notEmpty;
  method DIVIssue divFirst = divQ.first;
  method Action divDeq = divQ.deq;
  method Bool fpuNotEmpty = fpuQ.notEmpty;
  method FPUIssue fpuFirst = fpuQ.first;
  method Action fpuDeq = fpuQ.deq;
  method Bool brNotEmpty = brQ.notEmpty;
  method BRIssue brFirst = brQ.first;
  method Action brDeq = brQ.deq;
  method Bool csrNotEmpty = csrQ.notEmpty;
  method CSRIssue csrFirst = csrQ.first;
  method Action csrDeq = csrQ.deq;
endmodule

(* synthesize *)
module mkIssueNetwork(IssueNetwork);
  // Virtual output queues prevent a blocked scheduling or long-latency-unit
  // request from trapping unrelated work behind it.  The queues are grouped
  // by source bank; the destination queue is a separate registered boundary.
  Vector#(BankNum, IssueBankSource) sources <-
    replicateM(mkIssueBankSource);

  Fifo#(2, EXIssue) exQ <- mkEXIssueDestination;
  Fifo#(2, SchedReq) schedQ <- mkSchedIssueDestination;
  Fifo#(2, MULIssue) mulQ <- mkMULIssueDestination;
  Fifo#(2, DIVIssue) divQ <- mkDIVIssueDestination;
  Fifo#(2, FPUIssue) fpuQ <- mkFPUIssueDestination;
  Fifo#(2, BRIssue) brQ <- mkBRIssueDestination;
  Fifo#(2, CSRIssue) csrQ <- mkCSRIssueDestination;

  Vector#(IssueDestinationNum, Reg#(Bool)) cur <- replicateM(mkReg(True));
  Vector#(IssueDestinationNum, Vector#(BankNum, Reg#(Bool))) epochs <-
    replicateM(replicateM(mkReg(True)));

  (* fire_when_enabled *)
  rule route_issues;
    Vector#(BankNum, Bool) epochValues = newVector;
    Vector#(BankNum, Bool) candidates = newVector;

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[0][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].exNotEmpty;
    match {.choice, .e} = chooseIssueSource(candidates, epochValues, cur[0]);
    if (exQ.notFull &&& choice matches tagged Valid .idx) begin
      exQ.enq(sources[idx].exFirst);
      sources[idx].exDeq;
      epochs[0][idx] <= !e;
      cur[0] <= e;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[1][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].schedNotEmpty;
    match {.choice1, .e1} = chooseIssueSource(candidates, epochValues, cur[1]);
    if (schedQ.notFull &&& choice1 matches tagged Valid .idx) begin
      schedQ.enq(sources[idx].schedFirst);
      sources[idx].schedDeq;
      epochs[1][idx] <= !e1;
      cur[1] <= e1;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[2][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].mulNotEmpty;
    match {.choice2, .e2} = chooseIssueSource(candidates, epochValues, cur[2]);
    if (mulQ.notFull &&& choice2 matches tagged Valid .idx) begin
      mulQ.enq(sources[idx].mulFirst);
      sources[idx].mulDeq;
      epochs[2][idx] <= !e2;
      cur[2] <= e2;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[3][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].divNotEmpty;
    match {.choice3, .e3} = chooseIssueSource(candidates, epochValues, cur[3]);
    if (divQ.notFull &&& choice3 matches tagged Valid .idx) begin
      divQ.enq(sources[idx].divFirst);
      sources[idx].divDeq;
      epochs[3][idx] <= !e3;
      cur[3] <= e3;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[4][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].fpuNotEmpty;
    match {.choice4, .e4} = chooseIssueSource(candidates, epochValues, cur[4]);
    if (fpuQ.notFull &&& choice4 matches tagged Valid .idx) begin
      fpuQ.enq(sources[idx].fpuFirst);
      sources[idx].fpuDeq;
      epochs[4][idx] <= !e4;
      cur[4] <= e4;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[5][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].brNotEmpty;
    match {.choice5, .e5} = chooseIssueSource(candidates, epochValues, cur[5]);
    if (brQ.notFull &&& choice5 matches tagged Valid .idx) begin
      brQ.enq(sources[idx].brFirst);
      sources[idx].brDeq;
      epochs[5][idx] <= !e5;
      cur[5] <= e5;
    end

    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      epochValues[s] = epochs[6][s];
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      candidates[s] = sources[s].csrNotEmpty;
    match {.choice6, .e6} = chooseIssueSource(candidates, epochValues, cur[6]);
    if (csrQ.notFull &&& choice6 matches tagged Valid .idx) begin
      csrQ.enq(sources[idx].csrFirst);
      sources[idx].csrDeq;
      epochs[6][idx] <= !e6;
      cur[6] <= e6;
    end
  endrule

  Vector#(BankNum, Put#(IssuePacket)) ingressIfc = newVector;
  for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
    ingressIfc[s] =
      interface Put;
        method Action put(packet) = sources[s].put(packet);
      endinterface;

  interface ingress = ingressIfc;
  interface ex = toIssueOutput(exQ);
  interface sched = toIssueOutput(schedQ);
  interface mul = toIssueOutput(mulQ);
  interface divide = toIssueOutput(divQ);
  interface fpu = toIssueOutput(fpuQ);
  interface bru = toIssueOutput(brQ);
  interface csr = toIssueOutput(csrQ);
  method Bool csrPending;
    Vector#(BankNum, Bool) pending = newVector;
    for (Integer s = 0; s < valueOf(BankNum); s = s + 1)
      pending[s] = sources[s].csrNotEmpty;
    return csrQ.notEmpty || any(id, pending);
  endmethod
endmodule

function IssueOutput#(t) toIssueOutput(Fifo#(n, t) q)
  provisos (Bits#(t, tSz));
  return
    interface IssueOutput;
      method Bool notEmpty = q.notEmpty;
      method t first if (q.notEmpty) = q.first;
      method Action deq if (q.notEmpty) = q.deq;
    endinterface;
endfunction
