import DRAMControllerTypes::*;
import Shifter::*;
import ClientServerHelper::*;

typedef struct {
   Vector#(n, Bit#(shiftWidth)) sftV;
   Vector#(n, Bit#(addrWidth)) addrV;
   } DRAMBatchRdRequest#(numeric type n, numeric type addrWidth, numeric type sftWidth);

typedef Vector#(n, Bit#(dataWidth)) DRAMBatchRdResponse#(numeric type n, numeric type dataWidth);
   
typedef Server#(DRAMBatchRdRequest#(n, addrW, sftW), DRAMBatchRdResponse#(n, dtaW)) DRAMBatchRdServerIfc#(numeric type n, numeric type addrW, numeric type dtaW, numeric type sftW);

typedef Client#(DRAMBatchRdRequest#(n, addrW, sftW), DRAMBatchRdResponse#(n, dtaW)) DRAMBatchRdClientIfc#(numeric type n, numeric type addrW, numeric type dtaW, numeric type sftW);


interface DRAMRdBatchIfc#(numeric type logn, numeric type addrW, numeric type dtaW, numeric type sftW);
   interface DRAMRdBatchServer#(TExp#(logn), addrW, dtaW, sftW) batchServer;
   interface Client#(DDRRequest, DDRResponse) ddrClient;
endinterface

Integer rdLatency = 32;

module mkDRAMBatchServer(DRAMBatchIfc#(logn, addrW, dtaW, sftW)) provisos(
   NumAlias(n, TExp#(logn)));

   FIFO#(DRAMBatchRequest#(n, addrWidth, sftWidth)) reqQ <- mkLFIFO;
   FIFO#(DRAMBatchResponse#(n, dtaWidth)) respQ <- mkLFIFO;
   
   Reg#(Bit#(logn)) reqSel <- mkReg(0);
   
   FIFO#(Vector#(n, Bit#(sftW))) outstandingQ <- mkSizedFIFO(rdLatency+1);
   
   FIFO#(DDRRequest) dramReqQ <- mkBypassFIFO;
   
   rule doSplitReq;
      let reqV = reqQ.first;
      reqSel <= reqSel + 1;
      
      if (reqSel == 0) begin
         outstandingQ.enq(reqV.sftV);
      end
      
      if (reqSel == -1 ) begin
         reqQ.deq;
      end
      
      dramReqQ.enq(DDRRequest{
                             writeen: 0,
                             address: extend(reqV.addrV[reqSel]),
                             data: ? });
   endrule
   
   
   
   
   ByteShiftIfc#(DDRResponse, sftW) ddrShift <- mkPipelineRightShifter;
   
   
   Reg#(Bit#(logn)) respSel <- mkReg(0);
   rule doSftReq;
   endrule
   
   Reg#(Bit#(logn)) respCnt <- mkReg(0);
   
   Reg#(Bit#(TMul#(TSub#(n,1),dtaW))) tempResp <- mkRegU;
   rule doSftResp;
      let v <- ddrShift.getVal;
      
      Bit#(dtaW) newD = truncate(v);
      
      tempResp <= truncateLSB({newD,tempResp});
            
      if (respCnt == -1)
         respQ.enq(unpack({newD, oldV}));
         
   endrule
      
   interface batchServer = toServer(reqQ, respQ);
         
   interface ddrClient;
      interface request = toGet(dramReqQ);
      interface response;
         method Action put(DDRResponse dramResp);
            let sftV = outstandingQ.first;
            if (respSel == -1) outstandingQ.deq;
            ddrShift.rotateByteBy(dramResp, sftV[respSel]);
         endmethod
      endinterface
   endinterface
   
endmodule


   
   
   
   
   
   
