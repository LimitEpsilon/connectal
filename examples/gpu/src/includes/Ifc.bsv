typedef enum {
  START_LOAD_DATA   = 3'd0,
  DO_LOAD_DATA      = 3'd1,
  START_LOAD_KERNEL = 3'd2,
  DO_LOAD_KERNEL    = 3'd3,
  START_EXEC        = 3'd4,
  DO_EXEC           = 3'd5,
  DOWNLOAD_DATA     = 3'd6
} ProcState deriving (Bits, Eq, FShow);
interface ConnectalProcIndication;
  // START_LOAD_DATA, START_LOAD_KERNEL, START_EXEC, DO_EXEC
	method Action sendMessage(Bit#(34) mess);
	// DOWNLOAD_DATA
  method Action sendData(Bit#(32) data);
endinterface
interface ConnectalProcRequest;
  // {addr, data}, with addr == 1 when we are done
  method Action hostToProc(Bit#(64) data); // DO_LOAD_DATA, DO_LOAD_KERNEL
endinterface

