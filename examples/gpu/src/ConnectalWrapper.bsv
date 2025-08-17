`include "ConnectalProjectConfig.bsv"

import Vector::*;
import Connectable::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;

import DRAMController::*;
import DRAMControllerTypes::*;
import DDR4Controller::*;
import DDR4Common::*;
`ifdef SIMULATION
import DDR4Sim::*;
`else
import Clocks          :: *;
import DefaultValue    :: *;
`endif
import HostInterface::*;
import ClientServerHelper::*;

import Types::*;
import CMemTypes::*;
import ProcTypes::*;
import Ifc::*;

import MemInit::*;
import IMemory::*;
import Gpu::*;

module deriveDDR4Client#(MemoryClient#(a, d) c) (DDR4Client)
  provisos (
    Add#(TAdd#(a, 3), _1, DDR4AddrSz),
    Add#(d, _2, DDR4DataSz),
    Add#(TDiv#(d, 8), _3, TDiv#(DDR4DataSz, 8))
  );
  interface Get request;
    method ActionValue#(DDRRequest) get;
      let req <- c.request.get;
      DDR4Address address = extend({req.address, 3'b0});
      Bit#(TDiv#(DDR4DataSz, 8)) writeen = req.write ? extend(req.byteen) : 0;
      DDR4Data data = extend(req.data);
      return DDRRequest {writeen: writeen, address: address, datain: data};
    endmethod
  endinterface

  interface Put response;
    method Action put(DDRResponse resp);
      c.response.put(MemoryResponse {data: truncate(resp)});
    endmethod
  endinterface
endmodule

interface Top_Pins;
`ifndef SIMULATION
  interface DDR4_Pins_Dual_VCU108 pins_ddr4;
`endif
endinterface

interface ConnectalWrapper;
  interface ConnectalProcRequest connectProc;
  interface Top_Pins pins;
endinterface

module mkConnectalWrapper#(HostInterface host, ConnectalProcIndication ind) (ConnectalWrapper);
  Proc m <- mkProc;
  let ddrClient <- deriveDDR4Client(m.dMemClient);
  let iMem <- mkIMemory;
  Reg#(Maybe#(Addr)) startpc <- mkReg(tagged Invalid);

  mkConnection(iMem.iMemServer, m.iMemClient);
`ifdef SIMULATION
  DDR4_User_VCU108 ddrServer <- mkDDR4Simulator;
  let ddrInit <- mkMemInitDDR(ddrServer);
  mkConnection(ddrClient, ddrServer);
`else
  Clock curr_clk <- exposeCurrentClock();
  Reset curr_rst_n <- exposeCurrentReset();

  // DDR4 C1
  let sys_clk1 = host.tsys_clk1_300mhz;
  let sys_rst1 <- mkAsyncResetFromCR(20, sys_clk1);

  DDR4_Controller_VCU108 ddr4_ctrl_0 <- mkDDR4Controller_VCU108(defaultValue, clocked_by sys_clk1, reset_by sys_rst1);

  Clock ddr4clk0 = ddr4_ctrl_0.user.clock;
  Reset ddr4rstn0 = ddr4_ctrl_0.user.reset_n;

  let ddrServer <- mkDDR4ServerSync(ddr4_ctrl_0.user, ddr4clk0, ddr4rstn0, curr_clk, curr_rst_n);
  let ddrInit <- mkMemInitDDR(ddrServer);

  mkConnection(ddrClient, ddrServer);

  // DDR4 C2
  let sys_clk2 = host.tsys_clk1_300mhz_buf;
  let sys_rst2 <- mkAsyncResetFromCR(20, sys_clk2);

  DDR4_Controller_VCU108 ddr4_ctrl_1 <- mkDDR4Controller_VCU108(defaultValue, clocked_by sys_clk2, reset_by sys_rst2);

//  Clock ddr4clk1 = ddr4_ctrl_1.user.clock;
//  Reset ddr4rstn1 = ddr4_ctrl_1.user.reset_n;

//  let ddr_cli_300mhz_1 <- mkDDR4ClientSync(ddr_clients[1], curr_clk, curr_rst_n, ddr4clk1, ddr4rstn1);
//  mkConnection(ddr_cli_300mhz_1, ddr4_ctrl_1.user);
`endif // SIMULATION

  rule relay_message;
    let mess <- m.cpuToHost;
    ind.sendMessage(pack(mess));
  endrule

  rule signal_done (iMem.init.done && ddrInit.done && isValid(startpc));
    m.hostToCpu(fromMaybe(?, startpc));
    startpc <= tagged Invalid;
  endrule

  interface ConnectalProcRequest connectProc;
    method Action hostToCpu(Bit#(PhysAddrSz) addr, Data data, Addr pc, Bool last);
      let ld = MemInitLoad {addr: extend(addr), data: data};
      let e = last ? tagged InitDone : tagged InitLoad ld;
      iMem.init.request.put(e);
      ddrInit.request.put(e);
      if (last)
        startpc <= tagged Valid pc;
      else
        ind.wroteWord(0);
    endmethod
  endinterface

  interface Top_Pins pins;
`ifndef SIMULATION
    interface DDR4_Pins_Dual_VCU108 pins_ddr4;
      interface pins_c0 = ddr4_ctrl_0.ddr4;
      interface pins_c1 = ddr4_ctrl_1.ddr4;
    endinterface
`endif
  endinterface
endmodule

