package DRAMController;


import Clocks          :: *;
//import XilinxVC707DDR3::*;
//import Xilinx       :: *;
//import XilinxCells ::*;
import DDR4Controller::*;
import DDR4Common::*;

import Shifter::*;

import FIFO::*;
import BRAMFIFO::*;
import ConnectalBramFifo::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Counter::*;

import DRAMControllerTypes::*;

import XilinxSyncFifo::*;
import XilinxSyncFifoW784D32::*;
import XilinxSyncFifoW640D32::*;

import RWBramCore::*;

typedef 64 MAX_OUTSTANDING_READS;

instance Connectable#(DDR4Client, DDR4_User_VCU108);
  module mkConnection#(DDR4Client cli, DDR4_User_VCU108 usr)(Empty);
    rule request;
      let req <- cli.request.get;
      usr.request(truncate(req.address), req.writeen, req.datain);
    endrule

    rule response;
      let x <- usr.read_data;
      cli.response.put(x);
    endrule
  endmodule
endinstance

// Brings a DDR4Client from one clock domain to another.
module mkDDR4ClientSync#(DDR4Client ddr4, Clock sclk, Reset srst, Clock dclk, Reset drst) (DDR4Client);
  SyncFIFOIfc#(DDRRequest) reqs <- mkSyncBramFifo_w784_d32(sclk, srst, dclk);
  SyncFIFOIfc#(DDRResponse) resps <- mkSyncBramFifo_w640_d32(dclk, drst, sclk);

  mkConnection(toPut(reqs), toGet(ddr4.request));
  mkConnection(toGet(resps), toPut(ddr4.response));

  interface Get request = toGet(reqs);
  interface Put response = toPut(resps);
endmodule

// Brings a DDR4Server from one clock domain to another.
module mkDDR4ServerSync#(DDR4_User_VCU108 ddr4, Clock sclk, Reset srst, Clock dclk, Reset drst) (DDR4_User_VCU108);
  SyncFIFOIfc#(DDRRequest) reqs <- mkSyncBramFifo_w784_d32(dclk, drst, sclk);
  SyncFIFOIfc#(DDRResponse) resps <- mkSyncBramFifo_w640_d32(sclk, srst, dclk);

  rule do_request;
    let req <- toGet(reqs).get;
    ddr4.request(truncate(req.address), req.writeen, req.datain);
  endrule

  rule do_response;
    let x <- ddr4.read_data;
    toPut(resps).put(x);
  endrule

  interface Clock clock = dclk;
  interface Reset reset_n = drst;
  method init_done = True;
  method Action request(Bit#(28) address, Bit#(80) writeen, Bit#(640) datain);
    DDRRequest req = DDRRequest {
      writeen: writeen, address: extend(address), datain: datain
    };
    toPut(reqs).put(req);
  endmethod

  method ActionValue#(DDRResponse) read_data;
    let x <- toGet(resps).get;
    return x;
  endmethod
endmodule

endpackage: DRAMController
