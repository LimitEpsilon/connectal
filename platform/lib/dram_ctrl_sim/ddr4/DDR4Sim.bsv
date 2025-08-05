import Clocks::*;
import FIFO::*;
import Vector::*;
import RegFile::*;
import Connectable::*;
import GetPut::*;

import DDR4Controller::*;
import DDR4Common::*;

typedef Bit#(28) DDR4Address; // Use 8 banks (64 byte reads), each bank depth = 256MB / 8B = 32M = 2 ^ 25
typedef Bit#(80) ByteEn;
typedef Bit#(640) DDR4Data; // 2 DDR4 interfaces (c0, c1), with 5 banks each, each bank width 8 bytes

Bool debug = False;

function Bit#(dataW) fv_new_data
  (Bit#(dataW) old_data, Bit#(dataW) new_data, Bit #(bitW) strb)
  provisos (Mul#(8, bitW, dataW));

  function Bit#(8) f (Integer j) = strb [j] == 1'b1 ? 'hFF : 'h00;

  Vector#(bitW, Bit#(8)) v_mask = genWith(f);
  Bit#(dataW) mask = pack(v_mask);

  return ((old_data & (~ mask)) | (new_data & mask));
endfunction

module mkDDR4Simulator(DDR4_User_VCU108);
  RegFile#(Bit#(25), DDR4Data) data <- mkRegFileFull();
  FIFO#(DDR4Data) responses <- mkFIFO();

  Clock user_clock <- exposeCurrentClock;
  Reset user_reset_n <- exposeCurrentReset;

  interface clock = user_clock;
  interface reset_n = user_reset_n;
  method Bool init_done = True;

  method Action request(DDR4Address addr, ByteEn writeen, DDR4Data datain);
    if (debug) $display("%m, ddr req %h, %b, %h", addr, writeen, datain);
    if (addr[2:0] != 0) begin
      $display("DD4Sim: Need to preprocess accesses to DRAM to be 64-byte aligned, aborting...\n");
      $finish;
    end
    DDR4Data old_data = data.sub(truncate(addr >> 3));
    DDR4Data new_data = fv_new_data(old_data, datain, writeen);
    data.upd(truncate(addr >> 3), new_data);

    if (writeen == 0) responses.enq(new_data);
  endmethod

  method ActionValue#(DDR4Data) read_data;
    let v <- toGet(responses).get;
    if (debug) $display("%m, ddr resp %h", v);
    return v;
  endmethod

endmodule
