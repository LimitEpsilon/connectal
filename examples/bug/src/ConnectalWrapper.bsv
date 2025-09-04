`include "ConnectalProjectConfig.bsv"

import Vector::*;
import BRAM::*;
import GetPut::*;
import ClientServer::*;
import BypassBRAM::*;
import Fifo::*;

import Ifc::*;

typedef Bit#(1) Addr;
typedef Bit#(32) Data;

interface Top_Pins;
endinterface

interface ConnectalWrapper;
  interface ConnectalProcRequest connectProc;
  interface Top_Pins pins;
endinterface

(* synthesize *)
module mkMyBRAM(BRAM2Port#(Addr, Data));
  let m <- mkBypassBRAM;
  return m;
endmodule

module mkConnectalWrapper#(ConnectalProcIndication ind) (ConnectalWrapper);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bool) finished <- mkReg(False);

  Fifo#(64, Tuple3#(Bit#(32), Bit#(32), Bit#(32))) portAResFifo <- mkBRAMFifo(True, True);
  Fifo#(64, Tuple3#(Bit#(32), Bit#(32), Bit#(32))) portBResFifo <- mkBRAMFifo(True, True);
  let m <- mkMyBRAM;
  Vector#(2, Array#(Reg#(Data))) model <- replicateM(mkCRegU(2));
  Reg#(Bool) writeA <- mkRegU;
  Reg#(Data) dataA <- mkRegU;
  Reg#(Bool) writeB <- mkRegU;
  Reg#(Data) dataB <- mkRegU;
  Reg#(Bool) getB <- mkRegU;

  Reg#(Addr) addressA <- mkRegU;
  Reg#(Addr) addressB <- mkRegU;
  Reg#(Bool) failure <- mkRegU;

  Reg#(Bit#(32)) count <- mkRegU;
  Reg#(Bit#(32)) cycle <- mkRegU;
  Bit#(32) threshold = 32;

  (* fire_when_enabled *)
  (* execution_order = "testA, increment" *)
  (* execution_order = "testB, increment" *)
  (* execution_order = "putA, increment" *)
  (* execution_order = "putB, increment" *)
  rule increment(started);
    cycle <= cycle + 1;
    getB <= !getB;
  endrule

  (* fire_when_enabled *)
  rule call_done(started && finished);
    ind.done(extend(pack(failure)));
  endrule

  (* fire_when_enabled *)
  rule putA(started && !finished);
    let addrA = 0;
    let reqA = BRAMRequest {write: writeA, address: addrA, datain: dataA};

    m.portA.request.put(reqA);

    if (writeA) begin
      model[addrA][0] <= dataA;
      dataA <= dataA + 1;
    end

    writeA <= !writeA;
    addressA <= addrA;
  endrule

  (* fire_when_enabled *)
  rule putB(started && !finished);
    let addrB = 0;
    let reqB = BRAMRequest {write: writeB, address: addrB, datain: dataB};

    m.portB.request.put(reqB);

    if (writeB) begin
      model[addrB][1] <= dataB;
      dataB <= dataB + 1;
    end

    writeB <= !writeB;
    addressB <= addrB;
  endrule

  (* fire_when_enabled *)
  rule testA(started && !finished);
    let resp <- m.portA.response.get;
    let modelResp = model[addressA][0];
    portAResFifo.enq(tuple3(cycle, resp, modelResp));
  endrule

  (* fire_when_enabled *)
  rule testB(started && !finished);
    if (getB) begin
      let resp <- m.portB.response.get;
      let modelResp = model[addressB][0];
      portBResFifo.enq(tuple3(cycle, resp, modelResp));
    end
  endrule

  (* fire_when_enabled *)
  rule callInd(started && !finished);
    match {.cycleA, .valA, .modelA} = portAResFifo.first;
    match {.cycleB, .valB, .modelB} = portBResFifo.first;
    ind.res(cycleA, valA, modelA, cycleB, valB, modelB);
    portAResFifo.deq;
    portBResFifo.deq;
    count <= count + 1;
    if (valA != modelA || valB != modelB)
      failure <= True;
    if (count >= threshold)
      finished <= True;
  endrule

  interface ConnectalProcRequest connectProc;
    method Action start() if (!started);
      started <= True;

      dataA <= 0;
      writeA <= True;
      dataB <= 1000;
      writeB <= True;
      getB <= False;
      failure <= False;

      count <= 0;
      cycle <= 0;
    endmethod

    method Action finish() if (started);
      started <= False;
      finished <= False;
    endmethod
  endinterface

  interface Top_Pins pins;
  endinterface
endmodule

