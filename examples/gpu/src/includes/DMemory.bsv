/*

Copyright (C) 2012 Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Vector::*;
import Fifo::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;

import Types::*;
import CMemTypes::*;
import VectorMem::*;
import RegFile::*;
import MemInit::*;

interface DMemory;
  interface MemoryServer#(MemHeight, PhysDataSz) dMemServer;
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
  Fifo#(120, Bit#(PhysDataSz)) responses <- mkLatencyFifo(True, True); // simulate latency from DRAM

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

  interface dMemServer = mem;
  interface init = memInit;
endmodule

typedef VecMemoryRequest#(n, PhysAddrSz, TDiv#(DataSz, 8)) MemReq#(numeric type n);
typedef VecMemoryResponse#(n, TDiv#(DataSz, 8)) MemResp#(numeric type n);

interface DMemoryRouter#(numeric type n);
  interface Put#(MemReq#(n)) request;
  interface Get#(MemResp#(n)) response;
  interface MemoryClient#(MemHeight, PhysDataSz) dMemClient;
endinterface

(* synthesize *)
module mkDMemoryRouter(DMemoryRouter#(ThreadNum));
  Fifo#(1, MemoryRequest#(MemHeight, PhysDataSz)) reqs <- mkBypassFifo(True, True);
  Fifo#(1, MemoryResponse#(PhysDataSz)) resps <- mkBypassFifo(True, True);

  let m =
    interface MemoryServer;
      interface request = toPut(reqs);
      interface response = toGet(resps);
    endinterface;

  let s <- mkVecMemoryServer(m);

  interface request = s.request;
  interface response = s.response;
  interface MemoryClient dMemClient;
    interface request = toGet(reqs);
    interface response = toPut(resps);
  endinterface
endmodule

