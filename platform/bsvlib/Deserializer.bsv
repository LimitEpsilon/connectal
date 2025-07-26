import Pipe::*;
import FIFO::*;
import Shifter::*;

interface Deserializer#(type dataType);
   method Action start(Bit#(16) burstLen, Bit#(3) offset);
   interface PipeIn#(Bit#(256)) dataIn;
   interface PipeOut#(dataType) dataOut;
endinterface


module mkDeserializer(Deserializer#(dataT)) provisos(
   Bits#(dataT, dataSz),
   Add#(dataSz, a__, 256));
   
   Integer dWidth = valueOf(dataSz);
   
   FIFOF#(Bit#(256)) dataInQ <- mkFIFOF;
   FIFOF#(dataT) dataOutQ <- mkFIFOF;

   
   Reg#(Bit#(16)) packetCnt <- mkReg(0);
   
   Reg#(Bit#(3)) totalWords <- mkReg(0);
   
   Reg#(Bit#(16)) beatCnt <- mkReg(0);
   Reg#(Bit#(256)) buff <- mkRegU;
   
   Vector#(2, WordShiftIfc#(Bit#(512), 3)) rightSft <- replicateM(mkPipelineRightShifter);
         
   Reg#(UInt#(17)) wordCnt <- mkReg(0);
   
   FIFO#(Tuple3#(Bit#(16), Bit#(17), Bit#(3))) jobQ <- mkFIFO;
   

   
   FIFO#(Tuple3#(Bit#(256), Bit#(3))) extraShiftQ <- mkFIFO;
   
   // latency 3 + (1 for src 1) + 1 for simu enq/deq
   FIFO#(Bit#(1)) sftSrcQ <- mkSizedFIFO(3 + 1 + 1);
   
   rule doAlign ( !extraShift) ;
      let {expectedBeats, expectedWords, offset} = jobQ.first;

      if ( beatCnt + 1 == expectedBeat ) begin
         beatCnt <= 0;
         wordCnt <= 0;
         jobQ.deq;
         if ( wordCnt + zeroExtend(offset) < expectedWords ) begin
            // do an extra shift for the last data beat;
            rightSft[1].shiftBy(zeroExtend(data), offset);
            sftSrcQ.enq(1);
         end 
      end
      else begin
         beatCnt <= beatCnt + 1;
         wordCnt <= wordCnt + 8;
         sftSrcQ.enq(0);
      end
      
      buff <= data
      if ( beatCnt > 0 ) begin
         rightSft[0].shiftBy({data, buff}, offset);
      end
   endrule
   
   
   Reg#(Bit#(256)) alignedBuf <- mkReg(0);
   
   rule doDes;
      let data = alignedBuf;
      if ( bitCnt + fromInteger(dWidth) >= 256 ) begin
         let src <- toGet(sftSrcQ).get();
         data = rightSft[src].first;
      end
      
      bitCnt <= bitCnt + fromInteger(dWidth);
      
      alignedBuf <= data >> dWidth;

      dataOutQ.enq(truncate(data));
       
   endrule
   
   
   method Action start(Bit#(16) totalWords, Bit#(3) wordOffset);
      Bit#(17) expectedWords = totalWords + zeroExtend(wordOffset);
      Bit#(16) expectedBeats = (expectedWords + 7) >> 3;
   
      jobQ.enq(tuple2(expectedBeats, expectedWords, wordOffset));
   endmethod
   
   interface dataIn = toPipeIn(dataInQ);
   interface dataOut = toPipeOut(dataOutQ);
endmodule
