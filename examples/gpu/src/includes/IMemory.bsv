import FIFOF::*;
import SpecialFIFOs::*;
import BRAM::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;

import Types::*;
import CMemTypes::*;
import MemInit::*;

interface IMemory;
  interface MemoryServer#(AddrSz, DataSz) iMemServer;
  interface MemInitIfc init;
endinterface

(* synthesize *)
module mkIMemBRAM(BRAM1Port#(IMemAddr, Data));
  BRAM_Configure cfg = defaultValue;
  let ram <- mkBRAM1Server(cfg);
  return ram;
endmodule

(* synthesize *)
module mkIMemory(IMemory);
	// In simulation we always init memory from a fixed VMH file (for speed)
	let mem <- mkIMemBRAM;
	MemInitIfc memInit <- mkMemInitBRAM(mem);

  interface MemoryServer iMemServer;
    interface Put request;
      method Action put(MemoryRequest#(AddrSz, DataSz) req) if (memInit.done);
        mem.portA.request.put(BRAMRequest {
          write: False,
          responseOnWrite: False,
          address: truncate(req.address >> 2),
          datain: 0
        });
      endmethod
    endinterface

    interface Get response;
      method ActionValue#(MemoryResponse#(DataSz)) get if (memInit.done);
        let resp <- mem.portA.response.get;
        return MemoryResponse {data: resp};
      endmethod
    endinterface
  endinterface

  interface init = memInit;
endmodule

interface IMemoryRouter;
  interface Put#(MemoryRequest#(AddrSz, DataSz)) request;
  interface Get#(MemoryResponse#(DataSz)) response;
  interface MemoryClient#(AddrSz, DataSz) iMemClient;
endinterface

(* synthesize *)
module mkIMemoryRouter(IMemoryRouter);
  FIFOF#(MemoryRequest#(AddrSz, DataSz)) reqs <- mkBypassFIFOF;
  FIFOF#(MemoryResponse#(DataSz)) resps <- mkBypassFIFOF;

  interface request = toPut(reqs);
  interface response = toGet(resps);
  interface MemoryClient iMemClient;
    interface request = toGet(reqs);
    interface response = toPut(resps);
  endinterface
endmodule

