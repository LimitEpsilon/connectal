interface ConnectalProcIndication;
  method Action res(Bit#(32) cycleA, Bit#(32) valA, Bit#(32) modelA, Bit#(32) cycleB, Bit#(32) valB, Bit#(32) modelB);
  method Action done(Bit#(32) msg);
endinterface
interface ConnectalProcRequest;
  method Action start;
  method Action finish;
endinterface

