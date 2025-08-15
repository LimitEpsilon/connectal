import Types::*;
import CMemTypes::*;
import ProcTypes::*;
import Ifc::*;

import Gpu::*;

interface ConnectalWrapper;
  interface ConnectalProcRequest connectProc;
endinterface

module [Module] mkConnectalWrapper#(ConnectalProcIndication ind) (ConnectalWrapper);
  Proc m <- mkProc();

  rule relayMessage;
	  let mess <- m.cpuToHost;
    ind.sendMessage(pack(mess));
  endrule

  interface ConnectalProcRequest connectProc;
    method Action hostToCpu(Bit#(PhysAddrSz) addr, Data data, Addr pc, Bool last);
      if (!last) ind.wroteWord(0);
	    m.hostToCpu(addr, data, pc, last);
    endmethod
  endinterface
endmodule
