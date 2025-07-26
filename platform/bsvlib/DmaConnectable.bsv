import ConnectalMemory::*;
import Connectable::*;
import Pipe::*;

interface MemWriteEngineClient#(numeric type userWidth);
   interface Get#(MemengineCmd)       request;
   interface Put#(Bool)               done;
   interface PipeOut#(Bit#(userWidth)) data;
   interface PipeIn#(MemRequestCycles)     requestCycles;
endinterface

instance Connectable#(MemWriteEngineClient#(n), MemWriteEngineServer#(n));
   module mkConnection#(MemWriteEngineClient#(n) cli, MemWriteEngineServer#(n) ser)(Empty);
      mkConnection(cli.request, ser.request);
      mkConnection(cli.done, ser.done);
      mkConnection(cli.data, ser.data);
      mkConnection(cli.requestCycles, ser.requestCycles);
   endmodule
endinstance


