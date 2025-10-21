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
module mkCall(CoalTree#(ThreadNum, AddrSz, WarpId));
  function WarpId merge(WarpId x, WarpId y) = x;
  let t <- mkCoalTree(merge);
  return t;
endmodule

(* synthesize *)
module mkOneWarpIn(MergeTree#(6, Warp));
  let t <- mkMergeTree;
  return t;
endmodule

function
  Module#(Vector#(2, MergeTree#(6, Warp)))
  mkWarpIn = replicateM(mkOneWarpIn);

(* synthesize *)
module mkWarps(Fifo#(MaxDivergence, Warp));
  let fifo <- mkBRAMFifo(False, False);
  return fifo;
endmodule

(* synthesize *)
module mkIMemReq(MergeTree#(2, Warp));
  let t <- mkMergeTree;
  return t;
endmodule

(* synthesize *)
module mkOneRfIn(MergeTree#(5, Tuple2#(RFWrReq#(ThreadNum), Bit#(TSub#(LogWarpNum, 1)))));
  let t <- mkMergeTree;
  return t;
endmodule

function
  Module#(Vector#(2, MergeTree#(5, Tuple2#(RFWrReq#(ThreadNum), Bit#(TSub#(LogWarpNum, 1))))))
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
  method Action clear;
endinterface

// note that I removed guards from first and deq in mkLatencyFifo; check notEmpty explicitly
// why it's okay: we synchronize enq into execution unit and enq into STAGEOut
// therefore if we can get a response from the execution unit, STAGEOut must be notEmpty
// do_STAGE: dequeues from STAGEIn, enqueues to STAGEOut
// Assume execution units do more work at enq, and output is registered
(* synthesize *)
module mkCore(Core);
  // IF
  Fifo#(1, Warp) iMemReq <- mkBypassFifo(False, True);
  Reg#(Bool) lastIF <- mkReg(False);
  FIFOF#(Tuple3#(Addr, Warp, DecodedInst)) iMemResp <- mkFIFOF;
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

  // from ID, BRTaken, BRNTaken, CALL, START, IF
  let warpIn <- mkWarpIn;

  let warps <- mkWarps;
  FIFOF#(Warp) ifOut <- mkGFIFOF(False, True);
  Vector#(2, Scoreboard) scoreboards <- replicateM(mkScoreboard);
  // from RF, EX, MEM, CSR, START
  let rfIn <- mkRfIn;
  Vector#(2, FIFOF#(RFCont)) rfOut <- replicateM(mkGFIFOF(False, True));
  // from RF
  let schedIn <- mkSchedIn;
  // from RF
  let exIn <- mkExIn;
  Fifo#(3, EXCont) exOut <- mkCFFifo(True, False);
  // from RF
  let mulIn <- mkMulIn;
  Fifo#(5, EXCont) mulOut <- mkLatencyFifo(True, False);
  // from RF
  let divIn <- mkDivIn;
  Fifo#(TAdd#(1, DivStage), EXCont) divOut <- mkLatencyFifo(True, False);
  Vector#(2, Fifo#(8, Vector#(ThreadNum, Data))) stData <- replicateM(mkBRAMFifo(True, False));
  // from RF
  let brIn <- mkBrIn;
  Fifo#(3, BRCont) brOut <- mkCFFifo(True, False);
  // from EX
  let memIn <- mkMemIn;
  Fifo#(8, MEMCont) memOut <- mkBRAMFifo(True, False);
  // from RF
  let csrIn <- mkCsrIn;
  FIFOF#(CSRCont) csrOut <- mkGFIFOF(False, True);

  // signal error
  FIFOF#(void) error <- mkFIFOF;
  // signal clear
  Reg#(Bool) noClear <- mkReg(True);

  let logWarpNum = valueOf(LogWarpNum);

  // the clear method will drain all warps ready to be issued
  // we might need to introduce an epoch to distinguish btwn warps being cleared
  // and warps being submitted
  (* fire_when_enabled *)
  rule do_IF(noClear);
    Bool selected = warpIn[0].notEmpty || warpIn[1].notEmpty;
    if (selected || (iMemReq.notFull && warps.notEmpty)) $display("do_IF");
    Warp warp = ?;
    // select warpIn to clear
    if ((lastIF || !warpIn[1].notEmpty) && warpIn[0].notEmpty) begin
      warp = warpIn[0].first;
      warpIn[0].deq;
      lastIF <= False;
    end else if (warpIn[1].notEmpty) begin
      warp = warpIn[1].first;
      warpIn[1].deq;
      lastIF <= True;
    end

    // only enqueue warps with nonzero masks
    selected = selected && warp.mask != 0;
    // if warp can't be enqueued to iMemReq, enq to warps
    if (selected && (!iMemReq.notFull || warps.notEmpty))
      warps.enq(warp);
    // enq to iMemReq
    if (iMemReq.notFull) begin
      // warps only contains valid warps with nonzero masks
      if (warps.notEmpty) begin
        iMemReq.enq(warps.first);
        warps.deq;
      end else if (selected)
        iMemReq.enq(warp);
    end
  endrule

  (* fire_when_enabled *)
  rule cont_IF;
    match {.pc, .warp, .dInst} = iMemResp.first;
    match Warp {mask: .mask, wid: .wid, pc: .nTakenPc} = warp;
    match DecodedInst {
      iType: .iType,
      aluFunc: .aluFunc,
      mFunc: .mFunc,
      brFunc: .brFunc,
      conv: .conv,
      predN: .predN,
      dst: .dst,
      src1: .rs1,
      src2: .rs2,
      csr: .csr,
      immValid: .immValid,
      imm: .imm
    } = dInst;

    // debug output
    $display($format("pc: %h, wid: %d, mask: %b ", pc, wid, mask) + fshow(dInst));
    $fflush(stdout);

    let takenPc = pc + imm;
    let lowerWid = wid[0];
    Bit#(TSub#(LogWarpNum, 1)) upperWid = wid[logWarpNum-1 : 1];

    let rdReq = RFRdReq {conv: conv, rs1: rs1, rs2: rs2};
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
    if (iType == J)
      warpIn[lowerWid].iport[0].put(Warp {mask: mask, wid: wid, pc: takenPc});

    case (iType)
      // signal error
      Unsupported: error.enq(?);
      Fence: noAction;
      // enq into scoreboard
      default:
        scoreboards[lowerWid].iport[upperWid].put(tuple2(rdReq, rfCont));
    endcase

    iMemResp.deq;
  endrule

  for (Integer i = 0; i < 2; i = i + 1) begin
    (* fire_when_enabled *)
    rule do_RF;
      if (rfIn[i].notEmpty) begin
        $display("WB%0d", i);
        match {.wrReq, .wid} = rfIn[i].first;
        rfs[i].ask(fromWrReq(wrReq), wid);
        scoreboards[i].deq(True, wid, wrReq.rd);
        rfIn[i].deq;
      end else if (scoreboards[i].notEmpty) begin
        $display("do_RF%0d", i);
        match {.rdReq, .cont} = scoreboards[i].first;
        match RFCont {iType: .iType, warp: .warp, takenPc: .takenPc, dst: .dst} = cont;
        RFWrReq#(ThreadNum) wrReq = RFWrReq {
          conv: False,
          rd: dst,
          mask: warp.mask,
          datas: replicate(iType == J ? warp.pc : takenPc)
        };
        let upperWid = warp.wid[logWarpNum-1 : 1];

        case (iType)
          J, Auipc: rfIn[i].iport[0].put(tuple2(wrReq, upperWid));
          default: begin
            rfs[i].ask(fromRdReq(rdReq), upperWid);
            rfOut[i].enq(cont);
          end
        endcase
        scoreboards[i].deq(False, ?, ?);
      end
    endrule

    (* fire_when_enabled *)
    rule cont_RF;
      $display("cont_RF%0d", i);
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
      match RFResp {rv1: .rv1, rv2: .rv2} <- rfs[i].ans;

      Bit#(3) funct3 = pack(mFunc);
      MemMask memMask = unpack({funct3[2], funct3[0]});

      // select a representative value, used for scheduling ops
      let idx = fromMaybe(?, findIndex(id, unpack(warp.mask)));
      let rs1 = rv1[idx];
      let rs2 = rv2[idx];
      $display("pc+4: %x, wid: %d, rs1: %x, rs2: %x", warp.pc, warp.wid, rs1, rs2);

      let pred = pack(map(lsb, rv1)) ^ pack(replicate(predN));
      SchedReq schedReq = SchedReq {
        warp: warp,
        f: funct3,
        v1: (funct3 == fnPRED || funct3 == fnSPLIT) ? zeroExtend(pred) : rs1,
        v2: rs2
      };
      AluReq#(ThreadNum) exReq = AluReq {
        f: aluFunc,
        v1: rv1,
        v2: immValid ? replicate(imm) : rv2
      };
      EXCont exCont = EXCont {warp: warp, iType: iType, memMask: memMask, dst: dst};
      BruReq#(ThreadNum) brReq = BruReq {f: brFunc, v1: rv1, v2: rv2};
      BRCont brCont = BRCont {warp: warp, takenPc: takenPc};
      CsrReq#(ThreadNum) csrReq = CsrReq {wid: warp.wid, mask: warp.mask, csr: csr, write: iType == Csrw, data: rs1};
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
  rule do_EX;
    $display("do_EX");
    match {.req, .cont} = exIn.first;
    alus.enq(req);
    exOut.enq(cont);
    exIn.deq;
  endrule

  (* fire_when_enabled *)
  rule do_MUL;
    $display("do_MUL");
    match {.req, .cont} = mulIn.first;
    muls.enq(req);
    mulOut.enq(cont);
    mulIn.deq;
  endrule

  (* fire_when_enabled *)
  rule do_DIV;
    $display("do_DIV");
    match {.req, .cont} = divIn.first;
    divs.enq(req);
    divOut.enq(cont);
    divIn.deq;
  endrule

  (* fire_when_enabled *)
  rule cont_EX;
    $display("cont_EX");
    match EXCont {warp: .warp, iType: .iType, memMask: .memMask, dst: .dst} =
      muls.notEmpty ? mulOut.first :
      (divs.notEmpty ? divOut.first : exOut.first);
    let res = muls.notEmpty ? muls.first : (divs.notEmpty ? divs.first : alus.first);
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];

    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: False, rd: dst, mask: warp.mask,
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

    function Maybe#(KV#(AddrSz, WarpId)) genCall(Integer i);
      let kv = KV {key: res[i], val: warp.wid};
      return warp.mask[i] == 1 ? tagged Valid kv : tagged Invalid;
    endfunction

    case (iType)
      Alu, MulDiv, Jr: begin
        rfIn[lowerWid].iport[1].put(tuple2(rfReq, upperWid));
        if (iType == Jr) call.enq(genWith(genCall));
      end
      default: begin
        memIn.iport[0].put(tuple2(memReq, memCont));
        if (isWrite) stData[lowerWid].deq;
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
  rule do_BR;
    $display("do_BR");
    match {.req, .cont} = brIn.first;
    brus.enq(req);
    brOut.enq(cont);
    brIn.deq;
  endrule

  (* fire_when_enabled *)
  rule cont_BR;
    $display("cont_BR");
    match BRCont {warp: .warp, takenPc: .takenPc} = brOut.first;
    let res = brus.first;
    let tMask = warp.mask & pack(res);
    let nTMask = warp.mask & ~pack(res);
    let tWarp = Warp {mask: tMask, wid: warp.wid, pc: takenPc};
    let nTWarp = Warp {mask: nTMask, wid: warp.wid, pc: warp.pc};
    if (tMask != 0) warpIn[warp.wid[0]].iport[1].put(tWarp);
    if (nTMask != 0) warpIn[warp.wid[0]].iport[2].put(nTWarp);
    brus.deq;
    brOut.deq;
  endrule

  (* fire_when_enabled *)
  rule cont_CALL;
    $display("cont_CALL");
    match CoalResp {mask: .mask, kv: KV {key: .pc, val: .wid}} = call.first;
    $display("pc from CALL: %x", pc);
    let warp = Warp {mask: mask, wid: wid, pc: pc};
    warpIn[wid[0]].iport[3].put(warp);
    call.deq;
  endrule

  (* fire_when_enabled, no_implicit_conditions *)
  rule do_clear(!noClear);
    iMemReq.clear;
    lastIF <= False;
    warps.clear;
    ifOut.clear;
    exOut.clear;
    mulOut.clear;
    divOut.clear;
    for (Integer i = 0; i < 2; i = i + 1) begin
      rfOut[i].clear;
      stData[i].clear;
    end
    brOut.clear;
    memOut.clear;
    csrOut.clear;
    error.clear;
    noClear <= True;
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
      conv: False, rd: dst, mask: warp.mask, datas: genWith(genData)
    };
    rfIn[lowerWid].iport[2].put(tuple2(rfReq, upperWid));
    memOut.deq;
  endmethod

  method Action putIMemResp(Data resp);
    match Warp {mask: .mask, wid: .wid, pc: .pc} = ifOut.first;
    let warp = Warp {mask: mask, wid: wid, pc: pc + 4};
    case (resp[6 : 2])
      opJal, opJalr, opBranch, opSched: noAction;
      default: warpIn[wid[0]].iport[5].put(warp);
    endcase
    let dInst = decode(resp);
    iMemResp.enq(tuple3(pc, warp, dInst));
    ifOut.deq;
  endmethod

  method Action putCsrResp(CsrResp#(ThreadNum) resp);
    match CSRCont {warp: .warp, dst: .dst} = csrOut.first;
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];
    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: False, rd: dst, mask: warp.mask, datas: resp.datas
    };
    rfIn[lowerWid].iport[3].put(tuple2(rfReq, upperWid));
    csrOut.deq;
  endmethod

  method Action start(SchedResp resp);
    match SchedResp {warp: .warp, write: .write, top: .top} = resp;
    let lowerWid = warp.wid[0];
    let upperWid = warp.wid[logWarpNum-1 : 1];
    RFWrReq#(ThreadNum) rfReq = RFWrReq {
      conv: True, rd: 0, mask: warp.mask, datas: replicate(top)
    };
    if (write) rfIn[lowerWid].iport[4].put(tuple2(rfReq, upperWid));
    warpIn[lowerWid].iport[4].put(warp);
  endmethod

  method Action clear if (noClear);
    for (Integer i = 0; i < 2; i = i + 1) begin
      warpIn[i].clear;
      rfIn[i].clear;
      rfs[i].clear;
      scoreboards[i].clear;
    end
    alus.clear;
    muls.clear;
    divs.clear;
    brus.clear;
    call.clear;
    schedIn.clear;
    exIn.clear;
    mulIn.clear;
    divIn.clear;
    brIn.clear;
    memIn.clear;
    csrIn.clear;
    noClear <= False;
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
  rule process_iMem;
    $display("process_iMem");
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
  rule answer_iMem;
    $display("answer_iMem");
    let resp <- iMem.response.get;
    core.putIMemResp(resp.data);
  endrule

  (* fire_when_enabled *)
  rule process_dMem;
    $display("process_dMem");
    let req <- core.getDMemReq;
    if (req.write && req.addresses[0] == 64) // {1'b1, mhartid[5:0]}: address for putchar
      putchars.enq(req.datas[0][7:0]);
    else
      dMem.request.put(req);
  endrule

  (* fire_when_enabled *)
  rule answer_dMem;
    $display("answer_dMem");
    let resp <- dMem.response.get;
    core.putDMemResp(resp);
  endrule

  (* fire_when_enabled *)
  rule process_csr;
    $display("process_csr");
    let req <- core.getCsrReq;
    csrf.putCsrReq(req);
  endrule

  (* fire_when_enabled *)
  rule answer_csr;
    $display("answer_csr");
    let resp <- csrf.getCsrResp;
    core.putCsrResp(resp);
  endrule

  (* fire_when_enabled *)
  rule process_sched(csrf.started);
    $display("process_sched");
    let req <- core.getSchedReq;
    scheduler.putSchedReq(req);
  endrule

  (* fire_when_enabled *)
  rule answer_sched;
    $display("answer_sched");
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

