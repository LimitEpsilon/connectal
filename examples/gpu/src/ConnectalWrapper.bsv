`include "ConnectalProjectConfig.bsv"

import FIFOF::*;
import Vector::*;
import Connectable::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;

import DRAMController::*;
import DRAMControllerTypes::*;
import DDR4Controller::*;
import DDR4Common::*;
`ifdef SIMULATION
import DDR4Sim::*;
`else
import Clocks          :: *;
import DefaultValue    :: *;
`endif
import HostInterface::*;
import ClientServerHelper::*;

import Types::*;
import CMemTypes::*;
import ProcTypes::*;
import Ifc::*;

import MemInit::*;
import IMemory::*;
import Gpu::*;

function DDRRequest toDDR(MemoryRequest#(a, d) req)
  provisos (
    Add#(TAdd#(a, 3), _1, DDR4AddrSz),
    Add#(d, _2, DDR4DataSz),
    Add#(TDiv#(d, 8), _3, TDiv#(DDR4DataSz, 8))
  );

  DDR4Address address = extend({req.address, 3'b0});
  Bit#(TDiv#(DDR4DataSz, 8)) writeen = req.write ? extend(req.byteen) : 0;
  DDR4Data data = extend(req.data);
  return DDRRequest {writeen: writeen, address: address, datain: data};
endfunction

function MemoryResponse#(d) fromDDR(DDRResponse resp)
  provisos (Add#(d, _, DDR4DataSz));

  return MemoryResponse {data: truncate(resp)};
endfunction

interface Top_Pins;
`ifndef SIMULATION
  interface DDR4_Pins_Dual_VCU108 pins_ddr4;
`endif
endinterface

interface ConnectalWrapper;
  interface ConnectalProcRequest connectProc;
  interface Top_Pins pins;
endinterface

module mkConnectalWrapper#(HostInterface host, ConnectalProcIndication ind) (ConnectalWrapper);
  Proc proc                <- mkProc;
  let iMem                 <- mkIMemory;
  FIFOF#(Bit#(64)) dataQ   <- mkFIFOF;
  FIFOF#(Addr) addrQ       <- mkFIFOF;
  Reg#(Bool) iMemOOB       <- mkReg(False);
  Reg#(Bool) dMemOOB       <- mkReg(False);
  Reg#(UInt#(8)) loads     <- mkReg(0);
  RWire#(void) wasResp     <- mkRWire;
  RWire#(void) wasReq      <- mkRWire;
  Reg#(ProcState) state    <- mkReg(START_LOAD_DATA);
  Reg#(Data) kernelArg     <- mkReg(0);

`ifdef SIMULATION
  DDR4_User_VCU108 ddrServer <- mkDDR4Simulator;
  let ddrInit <- mkMemInitDDR(ddrServer);
`else
  Clock curr_clk <- exposeCurrentClock();
  Reset curr_rst_n <- exposeCurrentReset();

  // DDR4 C1
  let sys_clk1 = host.tsys_clk1_300mhz;
  let sys_rst1 <- mkAsyncResetFromCR(20, sys_clk1);

  DDR4_Controller_VCU108 ddr4_ctrl_0 <- mkDDR4Controller_VCU108(defaultValue, clocked_by sys_clk1, reset_by sys_rst1);

  Clock ddr4clk0 = ddr4_ctrl_0.user.clock;
  Reset ddr4rstn0 = ddr4_ctrl_0.user.reset_n;

  let ddrServer <- mkDDR4ServerSync(ddr4_ctrl_0.user, ddr4clk0, ddr4rstn0, curr_clk, curr_rst_n);
  let ddrInit <- mkMemInitDDR(ddrServer);

  // DDR4 C2
  let sys_clk2 = host.tsys_clk1_300mhz_buf;
  let sys_rst2 <- mkAsyncResetFromCR(20, sys_clk2);

  DDR4_Controller_VCU108 ddr4_ctrl_1 <- mkDDR4Controller_VCU108(defaultValue, clocked_by sys_clk2, reset_by sys_rst2);

//  Clock ddr4clk1 = ddr4_ctrl_1.user.clock;
//  Reset ddr4rstn1 = ddr4_ctrl_1.user.reset_n;

//  let ddr_cli_300mhz_1 <- mkDDR4ClientSync(ddr_clients[1], curr_clk, curr_rst_n, ddr4clk1, ddr4rstn1);
//  mkConnection(ddr_cli_300mhz_1, ddr4_ctrl_1.user);
`endif // SIMULATION

  (* fire_when_enabled, no_implicit_conditions *)
  rule update_loads;
    let incr = isValid(wasReq.wget);
    let decr = isValid(wasResp.wget);
    if (incr == decr) noAction;
    else if (incr) loads <= loads + 1;
    else loads <= loads - 1;
  endrule

  (* fire_when_enabled *)
  rule request_ddr(state == DO_EXEC);
    let x <- proc.dMemClient.request.get;
    let req = toDDR(x);
    Bit#(TSub#(AddrSz, PhysAddrSz)) upper = req.address[valueOf(AddrSz)-1 : valueOf(PhysAddrSz)];
    if (upper == 0) begin
      if (!x.write) wasReq.wset(?);
      ddrServer.request(truncate(req.address), req.writeen, req.datain);
    end else
      dMemOOB <= True;
  endrule

  (* fire_when_enabled *)
  rule response_ddr(loads != 0);
    let resp <- ddrServer.read_data;
    wasResp.wset(?);
    proc.dMemClient.response.put(fromDDR(resp));
  endrule

  (* fire_when_enabled *)
  rule request_imem;
    let req <- proc.iMemClient.request.get;
    Bit#(TSub#(AddrSz, TAdd#(IMemAddrSz, 2))) upper = req.address[valueOf(AddrSz)-1 : valueOf(IMemAddrSz)+2];
    if (upper == 0)
      iMem.iMemServer.request.put(req);
    else
      iMemOOB <= True;
  endrule

  (* fire_when_enabled *)
  rule response_imem;
    let resp <- iMem.iMemServer.response.get;
    proc.iMemClient.response.put(resp);
  endrule

  (* fire_when_enabled *)
  rule do_vx_upload_data_init(state == START_LOAD_DATA);
    let msg = CpuToHostData {c2hType: TellState, data: extend(pack(state))};
    ind.sendMessage(pack(msg));
    state <= DO_LOAD_DATA;
  endrule

  (* fire_when_enabled *)
  rule do_vx_upload_data(state == DO_LOAD_DATA);
    let loaded <- toGet(dataQ).get;
    Addr addr = loaded[63 : 32];
    Data data = loaded[31 : 0];
    if (addr[0] == 1) begin
      state <= START_LOAD_KERNEL;
    end else begin
      let ld = MemInitLoad {addr: addr, data: data};
      ddrInit.request.put(tagged InitLoad ld);
    end
    let msg = CpuToHostData {c2hType: SignalDone, data: 0};
    ind.sendMessage(pack(msg));
  endrule

  (* fire_when_enabled *)
  rule do_vx_upload_kernel_init(state == START_LOAD_KERNEL);
    let msg = CpuToHostData {c2hType: TellState, data: extend(pack(state))};
    ind.sendMessage(pack(msg));
    state <= DO_LOAD_KERNEL;
  endrule

  (* fire_when_enabled *)
  rule do_vx_upload_kernel(state == DO_LOAD_KERNEL);
    let loaded <- toGet(dataQ).get;
    Addr addr = loaded[63 : 32];
    Data data = loaded[31 : 0];
    if (addr[0] == 1) begin
      state <= START_EXEC;
      kernelArg <= data;
    end else begin
      let ld = MemInitLoad {addr: addr, data: data};
      iMem.init.request.put(tagged InitLoad ld);
      ddrInit.request.put(tagged InitLoad ld);
    end
    let msg = CpuToHostData {c2hType: SignalDone, data: 0};
    ind.sendMessage(pack(msg));
  endrule

  (* fire_when_enabled *)
  rule start_proc(state == START_EXEC);
    let memReady = iMem.init.done && ddrInit.done;
    if (!memReady) begin
      iMem.init.request.put(tagged InitDone);
      ddrInit.request.put(tagged InitDone);
    end else begin
      proc.hostToCpu(0, kernelArg);
      let msg = CpuToHostData {c2hType: TellState, data: extend(pack(state))};
      ind.sendMessage(pack(msg));
      state <= DO_EXEC;
    end
  endrule

  (* fire_when_enabled *)
  rule do_exec(state == DO_EXEC);
    if (dMemOOB) begin
      let msg = CpuToHostData {c2hType: ExitCode, data: 2};
      ind.sendMessage(pack(msg));
    end else if (iMemOOB) begin
      let msg = CpuToHostData {c2hType: ExitCode, data: 3};
      ind.sendMessage(pack(msg));
    end else begin
      let msg <- proc.cpuToHost;
      if (msg.c2hType == ExitCode && msg.data == 0) begin
        state <= DOWNLOAD_DATA;
      end
      ind.sendMessage(pack(msg));
    end
  endrule

  (* fire_when_enabled *)
  rule put_download_data_req(state == DOWNLOAD_DATA && loads == 0);
    let loaded <- toGet(dataQ).get;
    Addr addr = loaded[31 : 0];
    MemoryRequest#(MemHeight, PhysDataSz) x = MemoryRequest {
      write: False,
      byteen: ?,
      address: truncate(addr >> valueOf(MemWidth)),
      data: ?
    };
    let req = toDDR(x);
    if (addr[0] == 0)
      ddrServer.request(truncate(req.address), req.writeen, req.datain);
    addrQ.enq(addr);
  endrule

  (* fire_when_enabled *)
  rule get_download_data_resp(state == DOWNLOAD_DATA && loads == 0);
    let addr <- toGet(addrQ).get;
    Bit#(MemWidth) shamt = addr[valueOf(MemWidth)-1:0];
    if (addr[0] == 1) begin
      let msg = CpuToHostData {c2hType: SignalDone, data: 0};
      ind.sendMessage(pack(msg));
      state <= START_LOAD_DATA;
    end else begin
      let x <- ddrServer.read_data;
      ind.sendData(truncate(x >> {shamt, 3'b0}));
    end
  endrule

  interface ConnectalProcRequest connectProc;
    method Action hostToProc(Bit#(64) loaded) = dataQ.enq(loaded);
  endinterface

  interface Top_Pins pins;
`ifndef SIMULATION
    interface DDR4_Pins_Dual_VCU108 pins_ddr4;
      interface pins_c0 = ddr4_ctrl_0.ddr4;
      interface pins_c1 = ddr4_ctrl_1.ddr4;
    endinterface
`endif
  endinterface
endmodule

