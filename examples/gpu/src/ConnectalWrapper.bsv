import Vector::*;
import Connectable::*;
import GetPut::*;
import ClientServer::*;

import Types::*;
import CMemTypes::*;
import ProcTypes::*;
import Ifc::*;

import IMemory::*;
import DMemory::*;
import Gpu::*;

interface ConnectalWrapper;
  interface ConnectalProcRequest connectProc;
endinterface

module [Module] mkConnectalWrapper#(ConnectalProcIndication ind) (ConnectalWrapper);
  Proc m <- mkProc();
  let iMem <- mkIMemory;
  let dMem <- mkDMemory;
  Reg#(Maybe#(Addr)) startpc <- mkReg(tagged Invalid);

  mkConnection(iMem.iMemServer, m.iMemClient);
  mkConnection(dMem.dMemServer, m.dMemClient);

  rule relayMessage;
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
