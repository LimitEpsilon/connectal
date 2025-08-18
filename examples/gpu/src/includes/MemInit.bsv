import GetPut::*;
import BRAM::*;
import Memory::*;

import DDR4Common::*;
import DDR4Controller::*;

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

module mkMemInitBRAM#(BRAM1Port#(Bit#(w), Data) mem) (MemInitIfc)
  provisos (Add#(TAdd#(w, 2), h, AddrSz), Add#(w, _, AddrSz));
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitLoad .l: begin
          Bit#(h) upper = l.addr[31 : (valueOf(w)+2)];
          if (upper == 0) begin
            mem.portA.request.put(
              BRAMRequest {
                write: True,
                responseOnWrite: False,
                address: truncate(l.addr >> 2),
                datain: l.data
              }
            );
          end
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
          Bit#(TSub#(AddrSz, PhysAddrSz)) upper = l.addr[31 : valueOf(PhysAddrSz)];
          if (upper == 0) begin
            Bit#(MemWidth) shamt = l.addr[valueOf(MemWidth)-1:0];
            MemoryRequest#(MemHeight, PhysDataSz) req = MemoryRequest {
              write: True,
              byteen: 15 << shamt,
              address: truncate(l.addr >> valueOf(MemWidth)),
              data: extend(l.data) << {shamt, 3'b0}
            };
            mem.request.put(req);
          end
        end

        tagged InitDone: begin
          initialized <= True;
        end
      endcase
    endmethod
  endinterface

  method Bool done() = initialized;

endmodule

module mkMemInitDDR#(DDR4_User_VCU108 mem) (MemInitIfc);
  Reg#(Bool) initialized <- mkReg(False);

  interface Put request;
    method Action put(MemInit x) if (!initialized);
      case (x) matches
        tagged InitLoad .l: begin
          Bit#(TSub#(AddrSz, PhysAddrSz)) upper = l.addr[31 : valueOf(PhysAddrSz)];
          if (upper == 0) begin
            Bit#(MemWidth) shamt = l.addr[valueOf(MemWidth)-1:0];
            Bit#(28) address = {truncate(l.addr >> valueOf(MemWidth)), 3'b0};
            Bit#(80) writeen = 15 << shamt;
            Bit#(640) data = extend(l.data) << {shamt, 3'b0};
            mem.request(address, writeen, data);
          end
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
