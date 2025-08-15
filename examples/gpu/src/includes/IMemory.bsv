import Types::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;
import CMemTypes::*;
import RegFile::*;
import MemInit::*;
import BRAM::*;

interface IMemory;
  interface Put#(MemoryRequest#(AddrSz, DataSz)) request;
  interface Get#(MemoryResponse#(DataSz)) response;
  interface MemInitIfc init;
endinterface

typedef Bit#(16) IMemAddr;

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

  interface Put request;
    method Action put(MemoryRequest#(AddrSz, DataSz) req) if (memInit.done());
      mem.portA.request.put(BRAMRequest {
        write: False,
        responseOnWrite: False,
        address: truncate(req.address >> 2),
        datain: 0
      });
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(MemoryResponse#(DataSz)) get if (memInit.done());
      let resp <- mem.portA.response.get;
      return MemoryResponse {data: resp};
    endmethod
  endinterface

  interface MemInitIfc init = memInit;
endmodule

