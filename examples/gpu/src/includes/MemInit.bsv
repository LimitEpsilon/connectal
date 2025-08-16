import GetPut::*;
import BRAM::*;
import Memory::*;

import Types::*;
import CMemTypes::*;
import RegFile::*;

module mkMemInitRegFile(RegFile#(Bit#(w), Data) mem, MemInitIfc ifc) provisos (Add#(w, _, AddrSz));
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitLoad .l: begin
          mem.upd(truncate(l.addr), l.data);
        end

        tagged InitDone: begin
          initialized <= True;
        end
      endcase
    endmethod
  endinterface

  method Bool done() = initialized;

endmodule

module mkMemInitBRAM(BRAM1Port#(Bit#(w), Data) mem, MemInitIfc ifc) provisos (Add#(w, _, AddrSz));
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitLoad .l: begin
          mem.portA.request.put(
            BRAMRequest {
              write: True,
              responseOnWrite: False,
              address: truncate(l.addr >> 2),
              datain: l.data
            }
          );
        end

        tagged InitDone: begin
          initialized <= True;
        end
      endcase
    endmethod
  endinterface

  method Bool done() = initialized;

endmodule

module mkMemInitDRAM#(MemoryServer#(MemHeight, PhysDataSz) mem) (MemInitIfc);
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitLoad .l: begin
          Bit#(MemWidth) shamt = l.addr[valueOf(MemWidth)-1:0];
          MemoryRequest#(MemHeight, PhysDataSz) req = MemoryRequest {
            write: True,
            byteen: 15 << shamt,
            address: truncate(l.addr >> valueOf(MemWidth)),
            data: extend(l.data) << {shamt, 3'b0}
          };
          mem.request.put(req);
        end

        tagged InitDone: begin
          initialized <= True;
        end
      endcase
    endmethod
  endinterface

  method Bool done() = initialized;

endmodule

module mkDummyMemInit(MemInitIfc);
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitDone: begin
          initialized <= True;
        end
      endcase
    endmethod
  endinterface

  method Bool done() = initialized;

endmodule
