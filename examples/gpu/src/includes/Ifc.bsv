interface ConnectalProcIndication;
	method Action sendMessage(Bit#(18) mess);
  method Action wroteWord(Bit#(32) data);
endinterface
interface ConnectalProcRequest;
  // Bit#(PhysAddrSz) addr, Data data, Addr pc, Bool last
  method Action hostToCpu(Bit#(31) addr, Bit#(32) data, Bit#(32) pc, Bool last);
endinterface

