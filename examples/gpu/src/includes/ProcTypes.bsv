// Copyright (c) 2016 Massachusetts Institute of Technology

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Vector::*;
import ClientServer::*;
import Memory::*;

import Types::*;
import CMemTypes::*;

// cpu to host data type
typedef enum {
  SignalDone   = 2'd0,
  ExitCode     = 2'd1,
  PrintChar    = 2'd2,
  TellState    = 2'd3
} CpuToHostType deriving(Bits, Eq, FShow);

typedef struct {
  CpuToHostType c2hType;
  Bit#(16) data;
} CpuToHostData deriving(Bits, Eq, FShow);

interface Proc;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Action hostToCpu(Addr pc, Data kernel_arg);
  interface MemoryClient#(AddrSz, DataSz) iMemClient;
  interface MemoryClient#(MemHeight, PhysDataSz) dMemClient;
endinterface

// Register index (merged GPR + FPR)
typedef struct {
  Bool    isFpr;
  Bit#(5) idx;
} RIndx deriving (Bits, Eq, FShow);

// This encoding matches inst[31,30,29,27] since inst[28] is always 0
typedef enum {
  Swap    = 4'b0001,
  Add     = 4'b0000,
  Xor     = 4'b0010,
  And     = 4'b0110,
  Or      = 4'b0100,
  Min     = 4'b1000,
  Max     = 4'b1010,
  Minu    = 4'b1100,
  Maxu    = 4'b1110
} RVAmoOp deriving (Bits, Eq, FShow);

typedef enum {
  CSRustatus          = 12'h000,
  CSRuie              = 12'h004,
  CSRutvec            = 12'h005,
  CSRuscratch         = 12'h040,
  CSRuepc             = 12'h041,
  CSRucause           = 12'h042,
  CSRubadaddr         = 12'h043,
  CSRuip              = 12'h044,
  CSRfflags           = 12'h001,
  CSRfrm              = 12'h002,
  CSRfcsr             = 12'h003,
  CSRcycle            = 12'hc00,
  CSRtime             = 12'hc01,
  CSRinstret          = 12'hc02,
  CSRcycleh           = 12'hc80,
  CSRtimeh            = 12'hc81,
  CSRinstreth         = 12'hc82,
  CSRsstatus          = 12'h100,
  CSRsedeleg          = 12'h102,
  CSRsideleg          = 12'h103,
  CSRsie              = 12'h104,
  CSRstvec            = 12'h105,
  CSRsscratch         = 12'h140,
  CSRsepc             = 12'h141,
  CSRscause           = 12'h142,
  CSRsbadaddr         = 12'h143,
  CSRsip              = 12'h144,
  CSRsptbr            = 12'h180,
  CSRscycle           = 12'hd00,
  CSRstime            = 12'hd01,
  CSRsinstret         = 12'hd02,
  CSRscycleh          = 12'hd80,
  CSRstimeh           = 12'hd81,
  CSRsinstreth        = 12'hd82,
  CSRhstatus          = 12'h200,
  CSRhedeleg          = 12'h202,
  CSRhideleg          = 12'h203,
  CSRhie              = 12'h204,
  CSRhtvec            = 12'h205,
  CSRhscratch         = 12'h240,
  CSRhepc             = 12'h241,
  CSRhcause           = 12'h242,
  CSRhbadaddr         = 12'h243,
  CSRhcycle           = 12'he00,
  CSRhtime            = 12'he01,
  CSRhinstret         = 12'he02,
  CSRhcycleh          = 12'he80,
  CSRhtimeh           = 12'he81,
  CSRhinstreth        = 12'he82,
  CSRmisa             = 12'hf10,
  CSRmvendorid        = 12'hf11,
  CSRmarchid          = 12'hf12,
  CSRmimpid           = 12'hf13,
  CSRmhartid          = 12'hf14,
  CSRmstatus          = 12'h300,
  CSRmedeleg          = 12'h302,
  CSRmideleg          = 12'h303,
  CSRmie              = 12'h304,
  CSRmtvec            = 12'h305,
  CSRmscratch         = 12'h340,
  CSRmepc             = 12'h341,
  CSRmcause           = 12'h342,
  CSRmbadaddr         = 12'h343,
  CSRmip              = 12'h344,
  CSRmbase            = 12'h380,
  CSRmbound           = 12'h381,
  CSRmibase           = 12'h382,
  CSRmibound          = 12'h383,
  CSRmdbase           = 12'h384,
  CSRmdbound          = 12'h385,
  CSRmcycle           = 12'hf00,
  CSRmtime            = 12'hf01,
  CSRminstret         = 12'hf02,
  CSRmcycleh          = 12'hf80,
  CSRmtimeh           = 12'hf81,
  CSRminstreth        = 12'hf82,
  CSRmucounteren      = 12'h310,
  CSRmscounteren      = 12'h311,
  CSRmhcounteren      = 12'h312,
  CSRmucycle_delta    = 12'h700,
  CSRmutime_delta     = 12'h701,
  CSRmuinstret_delta  = 12'h702,
  CSRmscycle_delta    = 12'h704,
  CSRmstime_delta     = 12'h705,
  CSRmsinstret_delta  = 12'h706,
  CSRmhcycle_delta    = 12'h708,
  CSRmhtime_delta     = 12'h709,
  CSRmhinstret_delta  = 12'h70a,
  CSRmucycle_deltah   = 12'h780,
  CSRmutime_deltah    = 12'h781,
  CSRmuinstret_deltah = 12'h782,
  CSRmscycle_deltah   = 12'h784,
  CSRmstime_deltah    = 12'h785,
  CSRmsinstret_deltah = 12'h786,
  CSRmhcycle_deltah   = 12'h788,
  CSRmhtime_deltah    = 12'h789,
  CSRmhinstret_deltah = 12'h78a,
  // Vortex extensions
  CSRnc               = 12'hfc2,
  CSRnw               = 12'hfc1,
  CSRnt               = 12'hfc0,
  CSRtmask            = 12'hcc4,
  CSRcid              = 12'hcc2,
  CSRwid              = 12'hcc1,
  CSRtid              = 12'hcc0,
  CSRnone             = 12'hfff
} CSR deriving (Bits, Eq, FShow);

// opcode
typedef Bit#(5) Opcode;
Opcode opLoad    = 5'b00000;
Opcode opMiscMem = 5'b00011;
Opcode opOpImm   = 5'b00100;
Opcode opAuipc   = 5'b00101;
Opcode opStore   = 5'b01000;
Opcode opAmo     = 5'b01011;
Opcode opOp      = 5'b01100;
Opcode opLui     = 5'b01101;
Opcode opBranch  = 5'b11000;
Opcode opJalr    = 5'b11001;
Opcode opJal     = 5'b11011;
Opcode opSystem  = 5'b11100;
Opcode opSched   = 5'b00010;

// from https://github.com/bluespec/Flute/blob/master/src_Core/ISA/ISA_Decls.bsv
// ================================================================
// Floating Point Instructions

// ----------------------------------------------------------------
// Floating point Load-Store

Opcode opLoadFp  = 5'b00001;
Opcode opStoreFp = 5'b01001;

Bit#(3) f3_FSW = 3'b010;
Bit#(3) f3_FLW = 3'b010;

Bit#(3) f3_FSD = 3'b011;
Bit#(3) f3_FLD = 3'b011;

// ----------------------------------------------------------------
// Fused FP Multiply Add/Sub instructions (FM/FNM)

Opcode opFMAdd  = 5'b10000;
Opcode opFMSub  = 5'b10001;
Opcode opFNMSub = 5'b10010;
Opcode opFNMAdd = 5'b10011;

Bit#(2) f2_S = 2'b00;
Bit#(2) f2_D = 2'b01;
Bit#(2) f2_Q = 2'b11;

// ----------------------------------------------------------------
// All other FP intructions

Opcode opFp = 5'b10100;

// ----------------
// RV32F

Bit#(7) f7_FADD_S      = 7'b0000000;
Bit#(7) f7_FSUB_S      = 7'b0000100;
Bit#(7) f7_FMUL_S      = 7'b0001000;
Bit#(7) f7_FDIV_S      = 7'b0001100;
Bit#(7) f7_FSQRT_S     = 7'b0101100; Bit#(5) rs2_FSQRT_S   = 5'b00000;

Bit#(7) f7_FSGNJ_S     = 7'b0010000;                                   Bit#(3) f3_FSGNJ_S  = 3'b000;
Bit#(7) f7_FSGNJN_S    = 7'b0010000;                                   Bit#(3) f3_FSGNJN_S = 3'b001;
Bit#(7) f7_FSGNJX_S    = 7'b0010000;                                   Bit#(3) f3_FSGNJX_S = 3'b010;

Bit#(7) f7_FMIN_S      = 7'b0010100;                                   Bit#(3) f3_FMIN_S   = 3'b000;
Bit#(7) f7_FMAX_S      = 7'b0010100;                                   Bit#(3) f3_FMAX_S   = 3'b001;

Bit#(7) f7_FCVT_W_S    = 7'b1100000; Bit#(5) rs2_FCVT_W_S  = 5'b00000;
Bit#(7) f7_FCVT_WU_S   = 7'b1100000; Bit#(5) rs2_FCVT_WU_S = 5'b00001;
Bit#(7) f7_FMV_X_S     = 7'b1110000; Bit#(5) rs2_FMV_X_S   = 5'b00000; Bit#(3) f3_FMV_X_S  = 3'b000;

Bit#(7) f7_FCMP_S      = 7'b1010000;
Bit#(7) f7_FEQ_S       = 7'b1010000;                                   Bit#(3) f3_FEQ_S    = 3'b010;
Bit#(7) f7_FLT_S       = 7'b1010000;                                   Bit#(3) f3_FLT_S    = 3'b001;
Bit#(7) f7_FLE_S       = 7'b1010000;                                   Bit#(3) f3_FLE_S    = 3'b000;

Bit#(7) f7_FCLASS_S    = 7'b1110000; Bit#(5) rs2_FCLASS_S  = 5'b00000; Bit#(3) f3_FCLASS_S = 3'b001;
Bit#(7) f7_FCVT_S_W    = 7'b1101000; Bit#(5) rs2_FCVT_S_W  = 5'b00000;
Bit#(7) f7_FCVT_S_WU   = 7'b1101000; Bit#(5) rs2_FCVT_S_WU = 5'b00001;
Bit#(7) f7_FMV_S_X     = 7'b1111000; Bit#(5) rs2_FMV_S_X   = 5'b00000; Bit#(3) f3_FMV_S_X  = 3'b000;

typedef enum {
  FAdd = 5'b00000,
  FSub = 5'b00001,
  FMul = 5'b00010,
  FDiv = 5'b00011,
  FSqrt = 5'b01011,
  FSgnj = 5'b00100,
  FSgnjn = 5'b00110,
  FSgnjx = 5'b01100,
  FMin = 5'b00101,
  FMax = 5'b00111,
  FCvt_FF = 5'b01000,
  FCvt_WF = 5'b11000,
  FCvt_WUF = 5'b11001,
  FCvt_FW = 5'b11010,
  FCvt_FWU = 5'b11011,
  FEq = 5'b10110,
  FLt = 5'b10101,
  FLe = 5'b10100,
  FClass = 5'b11101,
  FMv_XF = 5'b11100,
  FMv_FX = 5'b11110,
  FMAdd = 5'b10000,
  FMSub = 5'b10001,
  FNMSub = 5'b10010,
  FNMAdd = 5'b10011
} FpuFunc deriving (Bits, Eq, FShow);

typedef enum {
  Single,
  Double
} FpuPrecision deriving (Bits, Eq, FShow);

typedef struct {
  FpuFunc         func;
  FpuPrecision    precision;
} FpuInst deriving (Bits, Eq, FShow);

// Rounding Modes
typedef enum {
  RNE  = 3'b000,
  RTZ  = 3'b001,
  RDN  = 3'b010,
  RUP  = 3'b011,
  RMM  = 3'b100,
  RDyn = 3'b111
} RVRoundMode deriving (Bits, Eq, FShow);

// For CSR, only following two are implemented 
// CSRR rd csr (i.e. CSRRS rd csr x0)
// CSRW csr rs1 (i.e. CSRRW x0 csr rs1)

// SCALL, SBREAK not implemented

typedef enum {
  Unsupported,
  Alu,
  MulDiv,
  Sched,
  Ld,
  St,
  J,
  Jr,
  Br,
  Fpu,
  Auipc,
  Csr,
  Fence
} IType deriving(Bits, Eq, FShow);

typedef enum {
  Eq  = 3'b000, // fnBEQ
  Neq = 3'b001, // fnBNE
  NT,
  Lt  = 3'b100, // fnBLT
  Ltu = 3'b110, // fnBLTU
  Ge  = 3'b101, // fnBGE
  Geu = 3'b111  // fnBGEU
} BrFunc deriving(Bits, Eq, FShow);

typedef enum {
  Add,
  Sub,
  And,
  Or,
  Xor,
  Slt,
  Sltu,
  Sll,
  Sra,
  Srl,
  Ceqz,
  Cnez
} AluFunc deriving(Bits, Eq, FShow);

typedef enum {
  Csrw = 3'b001, // fnCSRRW
  Csrr = 3'b010  // fnCSRRS
} CsrFunc deriving(Bits, Eq, FShow);

// has the same bit representation as funct3
// in the case that the representation changes, only change the order between Mult and Divide
typedef struct {
  Bool    isDiv;
  Bit#(2) mOp; // lower two bits of funct3
} MFunc deriving(Bits, Eq, FShow);

// has the same bit representation as {funct3[2], funct3[0]}
typedef enum {
  B  = 2'b00, // byte
  H  = 2'b01, // half
  BU = 2'b10, // byte unsigned
  HU = 2'b11  // half unsigned
} MemMask deriving(Bits, Eq, FShow);

typedef struct {
  IType    iType;
  AluFunc  aluFunc;
  FpuFunc  fpuFunc;
  Bit#(3)  funct3;
  Bool     conv; // split or join
  Bool     predN;
  RIndx    dst;
  RIndx    src1;
  RIndx    src2;
  RIndx    src3;
  CSR      csr;
  Bool     immValid;
  Data     imm;
} DecodedInst deriving(Bits, Eq, FShow);

typedef struct {
  Bit#(ThreadNum) mask;
  WarpId          wid;
  Addr            pc;
} Warp deriving(Bits, Eq, FShow);

// types of continuations waiting after each stage
typedef struct {
  Warp     warp; // PC + 4
  Addr     takenPc; // PC + imm for branch, jal
  IType    iType;
  AluFunc  aluFunc;
  FpuFunc  fpuFunc;
  Bit#(3)  funct3;
  Bool     predN; // rd != 0
  RIndx    dst;
  CSR      csr;
  Bool     immValid; // Mem, jalr
  Data     imm; // Mem, jalr
} RFCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp     warp;
  IType    iType; // Alu, Ld, St, Jr
  Bool     isMask;
  MemMask  memMask;
  RIndx    dst;
} EXCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp     warp;
  RIndx    dst;
} SimpleEXCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp  warp;
  Addr  takenPc; // PC + imm (branch taken)
} BRCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp                    warp;
  Bit#(1)                 sign;
  Bit#(TDiv#(DataSz, 8))  byteen;
  RIndx                   dst;
} MEMCont deriving(Bits, Eq, FShow);

// function code
// ALU
Bit#(3) fnADD     = 3'b000;
Bit#(3) fnSLL     = 3'b001;
Bit#(3) fnSLT     = 3'b010;
Bit#(3) fnSLTU    = 3'b011;
Bit#(3) fnXOR     = 3'b100;
Bit#(3) fnSR      = 3'b101;
Bit#(3) fnOR      = 3'b110;
Bit#(3) fnAND     = 3'b111;
// MUL, DIV
Bit#(3) fnMUL    = 3'b000; // lower 32 bits
Bit#(3) fnMULH   = 3'b001; // upper 32 bits, signed * signed
Bit#(3) fnMULHSU = 3'b010; // upper 32 bits, signed * unsigned
Bit#(3) fnMULHU  = 3'b011; // upper 32 bits, unsigned * unsigned
Bit#(3) fnDIV    = 3'b100; // quotient, signed / signed
Bit#(3) fnDIVU   = 3'b101; // quotient, unsigned / unsigned
Bit#(3) fnREM    = 3'b110; // remainder, signed % signed
Bit#(3) fnREMU   = 3'b111; // remainder, unsigned % unsigned
// Branch
Bit#(3) fnBEQ     = 3'b000;
Bit#(3) fnBNE     = 3'b001;
Bit#(3) fnBLT     = 3'b100;
Bit#(3) fnBGE     = 3'b101;
Bit#(3) fnBLTU    = 3'b110;
Bit#(3) fnBGEU    = 3'b111;
// Load
Bit#(3) fnLW      = 3'b010;
Bit#(3) fnLB      = 3'b000;
Bit#(3) fnLH      = 3'b001;
Bit#(3) fnLBU     = 3'b100;
Bit#(3) fnLHU     = 3'b101;
// Store
Bit#(3) fnSW      = 3'b010;
Bit#(3) fnSB      = 3'b000;
Bit#(3) fnSH      = 3'b001;
// Amo
Bit#(5) fnLR      = 5'b00010;
Bit#(5) fnSC      = 5'b00011;
// MiscMem
Bit#(3) fnFENCE   = 3'b000;
Bit#(3) fnFENCEI  = 3'b001;
// System
Bit#(3) fnCSRRW   = 3'b001;
Bit#(3) fnCSRRS   = 3'b010;
Bit#(3) fnCSRRC   = 3'b011;
Bit#(3) fnCSRRWI  = 3'b101;
Bit#(3) fnCSRRSI  = 3'b110;
Bit#(3) fnCSRRCI  = 3'b111;
Bit#(3) fnPRIV    = 3'b000;
Bit#(12) privSCALL = 12'h000;
// Sched
Bit#(3) fnTMC     = 3'b000;
Bit#(3) fnWSPAWN  = 3'b001;
Bit#(3) fnSPLIT   = 3'b010;
Bit#(3) fnJOIN    = 3'b011;
Bit#(3) fnBAR     = 3'b100;
Bit#(3) fnPRED    = 3'b101;

