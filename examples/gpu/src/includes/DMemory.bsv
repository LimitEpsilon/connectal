/*

Copyright (C) 2012 Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Types::*;
import Vector::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;
import VectorMem::*;
import CMemTypes::*;
import RegFile::*;
import MemInit::*;

interface DMemory;
  interface Put#(MemoryRequest#(MemHeight, PhysDataSz)) request;
  interface Get#(MemoryResponse#(PhysDataSz)) response;
  interface MemInitIfc init;
endinterface

function Bit#(dataW) fv_new_data
  (Bit#(dataW) old_data, Bit#(dataW) new_data, Bit #(bitW) strb)
  provisos (Mul#(8, bitW, dataW));

  function Bit#(8) f (Integer j) = strb [j] == 1'b1 ? 'hFF : 'h00;

  Vector#(bitW, Bit#(8)) v_mask = genWith(f);
  Bit#(dataW) mask = pack(v_mask);

  return ((old_data & (~ mask)) | (new_data & mask));
endfunction

(* synthesize *)
module mkDMemoryServer(MemoryServer#(MemHeight, PhysDataSz));
	// In simulation we always init memory from a fixed VMH file (for speed)
	RegFile#(Bit#(MemHeight), Bit#(PhysDataSz)) mem <- mkRegFileFull;
	FIFOF#(Bit#(PhysDataSz)) responses <- mkLFIFOF;

  interface Put request;
    method Action put(MemoryRequest#(MemHeight, PhysDataSz) req);
      match MemoryRequest {write: .write, byteen: .byteen, address: .address, data: .data} = req;
      let old_data = mem.sub(address);
      let new_data = fv_new_data(old_data, data, write ? byteen : 0);
      mem.upd(address, new_data);

      if (!write) responses.enq(new_data);
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(MemoryResponse#(PhysDataSz)) get;
      let v <- toGet(responses).get;
      return MemoryResponse {data: v};
    endmethod
  endinterface
endmodule

(* synthesize *)
module mkDMemory(DMemory);
  MemoryServer#(MemHeight, PhysDataSz) mem <- mkDMemoryServer;
	MemInitIfc memInit <- mkMemInitDRAM(mem);

	interface Put request;
	  method put if (memInit.done) = mem.request.put;
	endinterface
	interface Get response;
	  method get if (memInit.done) = mem.response.get;
	endinterface
  interface MemInitIfc init = memInit;
endmodule

typedef VecMemoryRequest#(n, PhysAddrSz, TDiv#(DataSz, 8)) MemReq#(numeric type n);
typedef VecMemoryResponse#(n, TDiv#(DataSz, 8)) MemResp#(numeric type n);

interface VectorDMemory#(numeric type n);
  interface Put#(MemReq#(n)) request;
  interface Get#(MemResp#(n)) response;
  interface MemInitIfc init;
endinterface

(* synthesize *)
module mkVectorDMemory(VectorDMemory#(ThreadNum));
  let m <- mkDMemory;
  VecMemoryServer#(ThreadNum, PhysAddrSz, TDiv#(DataSz, 8)) s <- mkVecMemoryServer(
    interface MemoryServer;
      interface request = m.request;
      interface response = m.response;
    endinterface
  );

  interface request = s.request;
  interface response = s.response;
  interface init = m.init;
endmodule

