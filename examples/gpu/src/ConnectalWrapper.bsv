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

import IMemory::*;
import DMemory::*;
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
  let iMem <- mkIMemory;
  let dMem <- mkDMemory;
  Reg#(Maybe#(Addr)) startpc <- mkReg(tagged Invalid);

  mkConnection(iMem.iMemServer, m.iMemClient);
  mkConnection(dMem.dMemServer, m.dMemClient);

  rule relay_message;
    let mess <- m.cpuToHost;
    ind.sendMessage(pack(mess));
  endrule

  rule signal_done (iMem.init.done && dMem.init.done && isValid(startpc));
    m.hostToCpu(fromMaybe(?, startpc));
    startpc <= tagged Invalid;
  endrule

  interface ConnectalProcRequest connectProc;
    method Action hostToCpu(Bit#(PhysAddrSz) addr, Data data, Addr pc, Bool last);
      let ld = MemInitLoad {addr: extend(addr), data: data};
      let e = last ? tagged InitDone : tagged InitLoad ld;
      iMem.init.request.put(e);
      dMem.init.request.put(e);
      if (last)
        startpc <= tagged Valid pc;
      else
        ind.wroteWord(0);
    endmethod
  endinterface
endmodule
