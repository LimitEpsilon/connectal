// types
import Types::*;
import ProcTypes::*;
import CMemTypes::*;

// storages
import RFile::*;
import IMemory::*;
import DMemory::*;
import CsrFile::*;
import Scheduler::*;

// functional units
import Decode::*;
import MulDiv::*;
import Exec::*;

// miscellaneous libraries
import Vector::*;
import Fifo::*;
import FIFOF::*;
import SpecialFIFOs::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;
import VectorMem::*;
import CoalTree::*;
import MergeTree::*;

typedef TMul#(ThreadNum, WarpNum) MaxDivergence;

(* synthesize *)
module mkCall(CoalTree#(ThreadNum, AddrSz, void));
  function void merge(void x, void y) = x;
  let t <- mkCoalTree(merge);
  return t;
endmodule

(* synthesize *)
module mkWarpIn(MergeTree#(4, Warp));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkOneWarps(Fifo#(TDiv#(MaxDivergence, 2), Warp));
  let fifo <- mkBRAMFifo(True, False);
  return fifo;
endmodule

function
  Module#(Vector#(2, Fifo#(TDiv#(MaxDivergence, 2), Warp)))
  mkWarps = replicateM(mkOneWarps);

(* synthesize *)
module mkIMemReq(MergeTree#(2, Warp));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkOneRfIn(MergeTree#(5, RFWrReq#(ThreadNum)));
  let t <- mkMergeTree;
  return t;
endmodule

function
  Module#(Vector#(2, MergeTree#(5, RFWrReq#(ThreadNum))))
  mkRfIn = replicateM(mkOneRfIn);

(* synthesize *)
module mkSchedIn(MergeTree#(2, SchedReq));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkExIn(MergeTree#(2, Tuple2#(AluReq#(ThreadNum), EXCont)));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkMulIn(MergeTree#(2, Tuple2#(MulReq#(ThreadNum), EXCont)));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkDivIn(MergeTree#(2, Tuple2#(DivReq#(ThreadNum), EXCont)));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkBrIn(MergeTree#(2, Tuple2#(BruReq#(ThreadNum), BRCont)));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkMemIn(MergeTree#(1, Tuple2#(MemReq#(ThreadNum), MEMCont)));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkCsrIn(MergeTree#(2, Tuple2#(CsrReq#(ThreadNum), CSRCont)));
  let t <- mkMergeTree;
  return t;
endmodule

interface Core;
  method ActionValue#(MemReq#(ThreadNum)) getDMemReq;
  method ActionValue#(Addr) getIMemReq;
  method ActionValue#(CsrReq#(ThreadNum)) getCsrReq;
  method ActionValue#(SchedReq) getSchedReq;
  method Action getError;
  method Action putDMemResp(MemResp#(ThreadNum) resp);
  method Action putIMemResp(Data resp);
  method Action putCsrResp(CsrResp#(ThreadNum) resp);
  method Action start(SchedResp resp);
endinterface

// note that I removed guards from first and deq in mkLatencyFifo; check notEmpty explicitly
// why it's okay: we synchronize enq into execution unit and enq into STAGEOut
// therefore if we can get a response from the execution unit, STAGEOut must be notEmpty
// doSTAGE: dequeues from STAGEIn, enqueues to STAGEOut
// Assume execution units do more work at enq, and output is registered
(* synthesize *)
module mkCore(Core);
  // IF
  FIFOF#(Warp) iMemReq <- mkBypassFIFOF;
  Reg#(Bool) lastIF <- mkReg(False);
  FIFOF#(Data) iMemResp <- mkBypassFIFOF;
  // RF, WB
  Vector#(2, VectorRFile#(ThreadNum)) rfs <- replicateM(mkVectorRFile);
  // EX
  let alus <- mkVectorAlu;
  // MUL
  let muls <- mkVectorMul;
  // DIV
  let divs <- mkVectorDiv;
  // BR
  let brus <- mkVectorBru;
  // CALL
  let call <- mkCall;

  // from START
  Vector#(2, FIFOF#(SchedResp)) startIn <- replicateM(mkLFIFOF);
  // from IF, BRTaken, BRNTaken, CALL
  let warpIn <- mkWarpIn;

  let warps <- mkWarps;
  Fifo#(2, Warp) ifOut <- mkPipelineFifo(True, False);
  Vector#(2, Scoreboard) scoreboards <- replicateM(mkScoreboard);
  // from IF, EX, MEM, CSR, START
  let rfIn <- mkRfIn;
  Vector#(2, Reg#(Bool)) lastWrite <- replicateM(mkReg(False));
  Vector#(2, FIFOF#(RFCont)) rfOut <- replicateM(mkLFIFOF);
  // from RF
  let schedIn <- mkSchedIn;
  // from RF
  let exIn <- mkExIn;
  Fifo#(2, EXCont) exOut <- mkPipelineFifo(True, False);
  // from RF
  let mulIn <- mkMulIn;
  Fifo#(5, EXCont) mulOut <- mkLatencyFifo(True, False);
  // from RF
  let divIn <- mkDivIn;
  Fifo#(TAdd#(1, DivStage), EXCont) divOut <- mkLatencyFifo(True, False);
  Vector#(2, FIFOF#(Vector#(ThreadNum, Data))) stData <- replicateM(mkGFIFOF(False, True));
  // from RF
  let brIn <- mkBrIn;
  Fifo#(2, BRCont) brOut <- mkPipelineFifo(True, False);
  // CALL
  Reg#(Bool) lastEpoch <- mkReg(False);
  Reg#(WarpId) lastWid <- mkReg(?);
  Fifo#(TAdd#(1, TLog#(ThreadNum)), WarpId) callOut <- mkLatencyFifo(True, False);
  // from EX
  let memIn <- mkMemIn;
  Fifo#(2, MEMCont) memOut <- mkLatencyFifo(True, False);
  // from RF
  let csrIn <- mkCsrIn;
  FIFOF#(CSRCont) csrOut <- mkGFIFOF(False, True);

  // signal error
  FIFOF#(void) error <- mkFIFOF;

  let logWarpNum = valueOf(LogWarpNum);

  (* fire_when_enabled *)
  rule issue;
    let warp = warpIn.notEmpty ? warpIn.first : ?;
    for (Integer i = 0; i < 2; i = i + 1) begin
      if (startIn[i].notEmpty) begin // explicitly prioritize new warps
        match SchedResp {warp: .newWarp, write: .write, top: .top} = startIn[i].first;
        let upperWid = newWarp.wid[logWarpNum-1 : 1];
        RFWrReq#(ThreadNum) rfReq = RFWrReq {
          conv: True, rd: 1, mask: newWarp.mask, wid: upperWid, datas: replicate(top)
        };
        warps[i].enq(newWarp);
        if (write) rfIn[i].iport[4].put(rfReq);
        startIn[i].deq;
      end else if (warpIn.notEmpty && warp.wid[0] == fromInteger(i)) begin
        warps[i].enq(warp);
      end
    end
    if (warpIn.notEmpty && !startIn[warp.wid[0]].notEmpty) begin // if warp was selected
      $display("doISSUE");
      warpIn.deq;
    end
  endrule

  (* fire_when_enabled *)
  rule doIF(iMemReq.notFull && (warps[0].notEmpty || warps[1].notEmpty));
    $display("doIF");

    if (lastIF) begin
      if (warps[0].notEmpty) begin
        lastIF <= False;
        iMemReq.enq(warps[0].first);
        warps[0].deq;
      end else begin
        iMemReq.enq(warps[1].first);
        warps[1].deq;
      end
    end else begin
      if (warps[1].notEmpty) begin
        lastIF <= True;
        iMemReq.enq(warps[1].first);
        warps[1].deq;
      end else begin
        iMemReq.enq(warps[0].first);
        warps[0].deq;
      end
    end
  endrule

  (* fire_when_enabled *)
  rule contIF(ifOut.notEmpty);
    match Warp {mask: .mask, wid: .wid, pc: .pc} = ifOut.first;
    let inst = iMemResp.first;
    let dInst = decode(inst);
    match DecodedInst {
      iType: .iType,
      aluFunc: .aluFunc,
      mFunc: .mFunc,
      brFunc: .brFunc,
      conv: .conv,
      predN: .predN,
      dstValid: .dstValid,
      dst: .dst,
      src1: .rs1,
      src2: .rs2,
      csr: .csr,
      immValid: .immValid,
      imm: .imm
    } = dInst;

    // debug output
    $display($format("pc: %h, insn: %x, wid: %d, mask: %b ", pc, inst, wid, mask) + fshow(dInst));
    $fflush(stdout);

    if (iType == Unsupported) error.enq(?);

    let takenPc = pc + imm;
    let nTakenPc = pc + 4;
    let lowerWid = wid[0];
    Bit#(TSub#(LogWarpNum, 1)) upperWid = wid[logWarpNum-1 : 1];
    let nextPc = inst[6 : 2] == opJal ? takenPc : nTakenPc;
    let retPc = inst[6 : 2] == opJal ? nTakenPc : takenPc;
    let warp = Warp {mask: mask, wid: wid, pc: nextPc};

    RFWrReq#(ThreadNum) wrReq = RFWrReq {
      conv: conv, rd: dst, wid: upperWid, mask: mask, datas: replicate(retPc)
    };
    let rdReq = RFRdReq {conv: conv, rs1: rs1, rs2: rs2, dstValid: dstValid};
    let rfCont = RFCont {
      warp: warp,
      takenPc: takenPc,
      iType: iType,
      aluFunc: aluFunc,
      mFunc: mFunc,
      brFunc: brFunc,
      predN: predN,
      immValid: immValid,
      imm: imm,
      csr: csr,
      dst: dst
    };

    // enq into warpIn
    case (inst[6 : 2])
      opJalr, opBranch, opSched: noAction;
      default: warpIn.iport[0].put(warp);
    endcase
    // enq into scoreboard or send write to RF
    case (inst[6 : 2])
      opMiscMem: noAction;
      opJal, opAuipc: rfIn[lowerWid].iport[0].put(wrReq);
      default: scoreboards[lowerWid].iport[upperWid].put(tuple2(rdReq, rfCont));
    endcase

    iMemResp.deq;
    ifOut.deq;
  endrule

  for (Integer i = 0; i < 2; i = i + 1) begin
    (* fire_when_enabled *)
    rule doRF;
      match {.rdReq, .cont} = scoreboards[i].notEmpty ? scoreboards[i].first : ?;
      let wrReq = rfIn[i].notEmpty ? rfIn[i].first : ?;
      if ((lastWrite[i] || !rfIn[i].notEmpty) && scoreboards[i].notEmpty) begin
        $display("doRF%0d", i);
        rfs[i].ask.put(fromRdReq(rdReq, cont));
        rfOut[i].enq(cont);
        scoreboards[i].deq(False, ?, ?);
        lastWrite[i] <= False;
      end else if (rfIn[i].notEmpty) begin
        $display("WB%0d", i);
        rfs[i].ask.put(fromWrReq(wrReq));
        scoreboards[i].deq(True, wrReq.wid, wrReq.conv ? 0 : wrReq.rd);
        rfIn[i].deq;
        lastWrite[i] <= True;
      end
    endrule

    (* fire_when_enabled *)
    rule contRF;
      $display("contRF%0d", i);
      match RFCont {
        warp: .warp,
        takenPc: .takenPc,
        iType: .iType,
        aluFunc: .aluFunc,
        mFunc: .mFunc,
        brFunc: .brFunc,
        predN: .predN,
        immValid: .immValid,
        imm: .imm,
        csr: .csr,
        dst: .dst
      } = rfOut[i].first;
      match RFResp {rv1: .rv1, rv2: .rv2} <- rfs[i].ans.get;

      Bit#(3) funct3 = pack(mFunc);
      MemMask memMask = unpack({funct3[2], funct3[0]});

      // select a representative value, used for scheduling ops
      let idx = fromMaybe(?, findIndex(id, unpack(warp.mask)));
      let rs1 = rv1[idx];
      let rs2 = rv2[idx];

      let pred = pack(map(lsb, rv1)) ^ pack(replicate(predN));

      $display("pc+4: %x, wid: %d, rs1: %x, rs2: %x", warp.pc, warp.wid, rs1, rs2);

      AluReq#(ThreadNum) exReq = AluReq {
        f: aluFunc,
        v1: rv1,
        v2: immValid ? replicate(imm) : rv2
      };
      SchedReq schedReq = SchedReq {
        warp: warp,
        f: funct3,
        v1: (funct3 == fnPRED || funct3 == fnSPLIT) ? zeroExtend(pred) : rs1,
        v2: rs2
      };
      EXCont exCont = EXCont {warp: warp, iType: iType, memMask: memMask, dst: dst};
      BruReq#(ThreadNum) brReq = BruReq {f: brFunc, v1: rv1, v2: rv2};
      BRCont brCont = BRCont {warp: warp, takenPc: takenPc};
      CsrReq#(ThreadNum) csrReq = CsrReq {wid: warp.wid, mask: warp.mask, csr: csr, write: iType == Csrw, datas: rv1};
      CSRCont csrCont = CSRCont {warp : warp, dst: dst};

      case (iType)
        Alu, Ld, LdMask, Jr: exIn.iport[i].put(tuple2(exReq, exCont));
        Sched: schedIn.iport[i].put(schedReq);
        MulDiv: case (mFunc) matches
          tagged Mult .f: begin
            MulReq#(ThreadNum) mulReq = MulReq{f: f, v1: rv1, v2: rv2};
            mulIn.iport[i].put(tuple2(mulReq, exCont));
          end
          tagged Divide .f: begin
            DivReq#(ThreadNum) divReq = DivReq{f: f, v1: rv1, v2: rv2};
            divIn.iport[i].put(tuple2(divReq, exCont));
          end
        endcase
        St, StMask: begin
          exIn.iport[i].put(tuple2(exReq, exCont));
          stData[i].enq(rv2);
        end
        Br: brIn.iport[i].put(tuple2(brReq, brCont));
        Csrr, Csrw: csrIn.iport[i].put(tuple2(csrReq, csrCont));
      endcase

      rfOut[i].deq;
    endrule
  end

  (* fire_when_enabled *)
  rule doEX;
    $display("doEX");
    match {.req, .cont} = exIn.first;
    alus.enq(req);
    exOut.enq(cont);
    exIn.deq;
  endrule

  (* fire_when_enabled *)
  rule doMUL;
    $display("doMUL");
    match {.req, .cont} = mulIn.first;
    muls.enq(req);
    mulOut.enq(cont);
    mulIn.deq;
  endrule

  (* fire_when_enabled *)
  rule doDIV;
    $display("doDIV");
    match {.req, .cont} = divIn.first;
    divs.enq(req);
    divOut.enq(cont);
    divIn.deq;
  endrule

  (* fire_when_enabled *)
  rule contEX;
    $display("contEX");
    match EXCont {warp: .warp, iType: .iType, memMask: .memMask, dst: .dst} =
      muls.notEmpty ? mulOut.first :
      (divs.notEmpty ? divOut.first : exOut.first);
    let res = muls.notEmpty ? muls.first : (divs.notEmpty ? divs.first : alus.first);
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];

    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: False, rd: dst, wid: upperWid, mask: warp.mask,
      datas: iType == Jr ? replicate(warp.pc) : res
    };

    Bool isH = unpack(pack(memMask)[0]);
    Bit#(1) sign = ~(pack(memMask)[1]); // 1'b0 if BU/HU
    Bool isMask = iType == StMask || iType == LdMask;
    Bool isWrite = iType == St || iType == StMask;
    Vector#(ThreadNum, Bit#(PhysAddrSz)) addresses = map(truncate, res);
    Bit#(TDiv#(DataSz, 8)) en =
      isMask ?
      (isH ? zeroExtend(2'b11) : zeroExtend(1'b1)) :
      signExtend(1'b1);
    MemReq#(ThreadNum) memReq = VecMemoryRequest {
      write: isWrite, byteen: en, addresses: addresses, datas: stData[lowerWid].first, mask: warp.mask
    };
    let memCont = MEMCont {warp: warp, sign: sign, byteen: en, dst: dst};

    function Maybe#(KV#(k, void)) filt(Bool v, Bit#(k) x);
      let kv = KV {key: x, val: ?};
      return v ? tagged Valid kv : tagged Invalid;
    endfunction

    case (iType)
      Alu, MulDiv: begin
        rfIn[lowerWid].iport[1].put(rfReq);
      end
      Ld, LdMask: begin
        memIn.iport[0].put(tuple2(memReq, memCont));
      end
      St, StMask: begin
        memIn.iport[0].put(tuple2(memReq, memCont));
        stData[lowerWid].deq;
      end
      Jr: begin
        rfIn[lowerWid].iport[1].put(rfReq);
        call.enq(zipWith(filt, unpack(warp.mask), res));
        callOut.enq(warp.wid);
      end
    endcase

    if (muls.notEmpty) begin
      muls.deq; mulOut.deq;
    end else if (divs.notEmpty) begin
      divs.deq; divOut.deq;
    end else begin
      alus.deq; exOut.deq;
    end
  endrule

  (* fire_when_enabled *)
  rule doBR;
    $display("doBR");
    match {.req, .cont} = brIn.first;
    brus.enq(req);
    brOut.enq(cont);
    brIn.deq;
  endrule

  (* fire_when_enabled *)
  rule contBR;
    $display("contBR");
    match BRCont {warp: .warp, takenPc: .takenPc} = brOut.first;
    let res = brus.first;
    let tMask = warp.mask & pack(res);
    let nTMask = warp.mask & ~pack(res);
    let tWarp = Warp {mask: tMask, wid: warp.wid, pc: takenPc};
    let nTWarp = Warp {mask: nTMask, wid: warp.wid, pc: warp.pc};
    if (tMask != 0) warpIn.iport[1].put(tWarp);
    if (nTMask != 0) warpIn.iport[2].put(nTWarp);
    brus.deq;
    brOut.deq;
  endrule

  (* fire_when_enabled *)
  rule doCALL;
    $display("doCALL");
    let curE = call.getEpoch;
    let epochEq = lastEpoch == curE;
    let wid = epochEq ? lastWid : callOut.first;
    match CoalResp {mask: .mask, kv: KV {key: .pc}} = call.first;
    $display("pc from CALL: %x", pc);
    if (!epochEq) begin
      $display("epoch not equal, changing warp to %d", wid);
      lastEpoch <= curE;
      lastWid <= wid;
      callOut.deq;
    end
    warpIn.iport[3].put(Warp {mask: mask, wid: wid, pc: pc});
    call.deq;
  endrule

  method ActionValue#(MemReq#(ThreadNum)) getDMemReq;
    match {.req, .cont} = memIn.first;
    if (!req.write) memOut.enq(cont);
    memIn.deq;

    return req;
  endmethod

  method ActionValue#(Addr) getIMemReq;
    let warp = iMemReq.first;
    ifOut.enq(warp);
    iMemReq.deq;

    return warp.pc;
  endmethod

  method ActionValue#(CsrReq#(ThreadNum)) getCsrReq;
    match {.req, .cont} = csrIn.first;
    csrOut.enq(cont);
    csrIn.deq;

    return req;
  endmethod

  method ActionValue#(SchedReq) getSchedReq;
    let req = schedIn.first;
    schedIn.deq;

    return req;
  endmethod

  method Action getError = error.deq;

  method Action putDMemResp(MemResp#(ThreadNum) resp);
    match MEMCont {warp: .warp, sign: .sign, byteen: .en, dst: .dst} = memOut.first;
    Bool isWord = unpack(en[3]);
    Bool isHalf = unpack(en[1]);
    function Data genData(Integer i);
      Data word = resp.datas[i];
      Bit#(TSub#(DataSz, 16)) halfUpper = pack(replicate(sign & word[15]));
      Bit#(TSub#(DataSz, 8)) byteUpper = pack(replicate(sign & word[7]));
      return isWord ? word :
        (isHalf ? {halfUpper, word[15:0]} : {byteUpper, word[7:0]});
    endfunction
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];
    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: False, rd: dst, wid: upperWid, mask: warp.mask, datas: genWith(genData)
    };
    rfIn[lowerWid].iport[2].put(rfReq);
    memOut.deq;
  endmethod

  method Action putIMemResp(Data resp) = iMemResp.enq(resp);

  method Action putCsrResp(CsrResp#(ThreadNum) resp);
    match CSRCont {warp: .warp, dst: .dst} = csrOut.first;
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];
    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: False, rd: dst, wid: upperWid, mask: warp.mask, datas: resp.datas
    };
    rfIn[lowerWid].iport[3].put(rfReq);
    csrOut.deq;
  endmethod

  method Action start(SchedResp resp);
    startIn[resp.warp.wid[0]].enq(resp);
  endmethod
endmodule

module mkProc(Proc);
  let core <- mkCore;
  // IF
  let iMem <- mkIMemoryRouter;
  // MEM
  let dMem <- mkDMemoryRouter;
  // CSR
  let csrf <- mkCsrFile;
  // SCHED
  let scheduler <- mkScheduler;
  Reg#(Addr) startpc <- mkReg(0);
  Reg#(Bool) started <- mkReg(False);

  FIFOF#(Bit#(8)) putchars <- mkGFIFOF(False, True);
  FIFOF#(void) error <- mkGFIFOF(False, True);
  FIFOF#(void) done <- mkGFIFOF(False, True);

  (* fire_when_enabled *)
  rule processIMem;
    $display("processIMem");
    let pc <- core.getIMemReq;
    MemoryRequest#(AddrSz, DataSz) req = MemoryRequest{
      write: False,
      byteen: ?,
      address: pc,
      data: ?
    };
    iMem.request.put(req);
  endrule

  (* fire_when_enabled *)
  rule answerIMem;
    $display("answerIMem");
    let resp <- iMem.response.get;
    core.putIMemResp(resp.data);
  endrule

  (* fire_when_enabled *)
  rule processDMem;
    $display("processDMem");
    let req <- core.getDMemReq;
    if (req.write && req.addresses[0] == 64) // {1'b1, mhartid[5:0]}: address for putchar
      putchars.enq(req.datas[0][7:0]);
    else
      dMem.request.put(req);
  endrule

  (* fire_when_enabled *)
  rule answerDMem;
    $display("answerDMem");
    let resp <- dMem.response.get;
    core.putDMemResp(resp);
  endrule

  (* fire_when_enabled *)
  rule processCsr;
    $display("processCsr");
    let req <- core.getCsrReq;
    csrf.putCsrReq(req);
  endrule

  (* fire_when_enabled *)
  rule answerCsr;
    $display("answerCsr");
    let resp <- csrf.getCsrResp;
    core.putCsrResp(resp);
  endrule

  (* fire_when_enabled *)
  rule processSched(csrf.started);
    $display("processSched");
    let req <- core.getSchedReq;
    scheduler.putSchedReq(req);
  endrule

  (* fire_when_enabled *)
  rule answerSched;
    $display("answerSched");
    let resp <- scheduler.getSchedResp;
    core.start(resp);
  endrule

  (* fire_when_enabled *)
  rule start_csr(!csrf.started && started);
    csrf.start;
    let dummy = Warp {wid: 1, pc: 0, mask: 0};
    let req = SchedReq {warp: dummy, f: fnWSPAWN, v1: 2, v2: startpc};
    scheduler.putSchedReq(req);
    $display("Start at pc %x\n", startpc);
    $fflush(stdout);
  endrule

  (* fire_when_enabled *)
  rule get_error;
    core.getError;
    error.enq(?);
  endrule

  (* fire_when_enabled *)
  rule get_done;
    scheduler.getDone;
    done.enq(?);
  endrule

  method ActionValue#(CpuToHostData) cpuToHost;
    if (putchars.notEmpty) begin
      let ret = CpuToHostData {c2hType: PrintChar, data: extend(putchars.first)};
      putchars.deq;
      return ret;
    end else if (error.notEmpty) begin
      let ret = CpuToHostData {c2hType: ExitCode, data: 1};
      error.deq;
      return ret;
    end else if (done.notEmpty) begin
      let ret = CpuToHostData {c2hType: ExitCode, data: 0};
      done.deq;
      return ret;
    end else begin
      let ret <- csrf.cpuToHost;
      return ret;
    end
  endmethod

  method Action hostToCpu(Addr pc) if (!started);
    startpc <= pc;
    started <= True;
  endmethod

  interface iMemClient = iMem.iMemClient;
  interface dMemClient = dMem.dMemClient;
endmodule

