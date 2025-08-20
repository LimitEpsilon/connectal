/*

Copyright (C) 2012

Arvind <arvind@csail.mit.edu>
Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Vector::*;
import ClientServer::*;
import Memory::*;

import Types::*;
import CMemTypes::*;

// cpu to host data type
typedef enum {
	ExitCode = 2'd0,
	PrintChar = 2'd1,
	PrintIntLow = 2'd2,
	PrintIntHigh = 2'd3
} CpuToHostType deriving(Bits, Eq, FShow);

typedef struct {
	CpuToHostType c2hType;
	Bit#(16) data;
} CpuToHostData deriving(Bits, Eq, FShow);

interface Proc;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Action hostToCpu(Addr pc);
  interface MemoryClient#(AddrSz, DataSz) iMemClient;
  interface MemoryClient#(MemHeight, PhysDataSz) dMemClient;
endinterface

// general purpose reg index
typedef Bit#(5) RIndx;

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

// CSR index
typedef 12 CsrSz;
typedef Bit#(CsrSz) CsrIndx;
CsrIndx csrInstret = 12'hc02;
CsrIndx csrCycle   = 12'hc00;
CsrIndx csrMhartid = 12'hf14;
CsrIndx csrMtohost = 12'h780;
CsrIndx csrScratch = 12'h340;
CsrIndx csrNc      = 12'hfc2;
CsrIndx csrNw      = 12'hfc1;
CsrIndx csrNt      = 12'hfc0;
CsrIndx csrCid     = 12'hcc2;
CsrIndx csrWid     = 12'hcc1;
CsrIndx csrTid     = 12'hcc0;
CsrIndx csrTmask   = 12'hcc4;

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
	LdMask,
	St,
	StMask,
	J,
	Jr,
	Br,
	Auipc,
	Csrr,
	Csrw,
	Fence
} IType deriving(Bits, Eq, FShow);

typedef enum {
	Eq,
	Neq,
	AT,
	NT,
	Lt,
	Ge,
	Ltu,
	Geu
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

// has the same bit representation as funct3
// in the case that the representation changes, only change the order between Mult and Divide
typedef union tagged {
  Bit#(2) Mult; // lower two bits of funct3
  Bit#(2) Divide; // lower two bits of funct3
} MFunc deriving(Bits, Eq, FShow);

// has the same bit representation as {funct3[2], funct3[0]}
typedef enum {
  B, // byte, 2'b00
  H, // half, 2'b01
  BU, // byte unsigned, 2'b10
  HU // half unsigned, 2'b11
} MemMask deriving(Bits, Eq, FShow);

typedef void Exception;

typedef struct {
  Addr pc;
  Addr nextPc;
  IType brType;
  Bool taken;
  Bool mispredict;
} Redirect deriving (Bits, Eq, FShow);

typedef struct {
  IType    iType;
  AluFunc  aluFunc;
  MFunc    mFunc;
  BrFunc   brFunc;
  Bool     conv; // split or join
  Bool     predN;
  RIndx    dst;
  RIndx    src1;
  RIndx    src2;
  CsrIndx  csr;
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
  MFunc    mFunc;
  BrFunc   brFunc;
  Bool     predN; // rd != 0
  RIndx    dst;
  CsrIndx  csr;
  Bool     immValid; // Mem, jalr
  Data     imm; // Mem, jalr
} RFCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp     warp;
  IType    iType; // Alu, MulDiv, Ld, LdMask, St, StMask, Jr
  MemMask  memMask;
  RIndx    dst;
} EXCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp  warp;
  Addr  takenPc; // PC + imm (branch taken)
} BRCont deriving(Bits, Eq, FShow);

typedef struct {
  Warp   warp;
  RIndx  dst;
} CSRCont deriving(Bits, Eq, FShow);

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
Bit #(3) fnMUL    = 3'b000; // lower 32 bits
Bit #(3) fnMULH   = 3'b001; // upper 32 bits, signed * signed
Bit #(3) fnMULHSU = 3'b010; // upper 32 bits, signed * unsigned
Bit #(3) fnMULHU  = 3'b011; // upper 32 bits, unsigned * unsigned
Bit #(3) fnDIV    = 3'b100; // quotient, signed / signed
Bit #(3) fnDIVU   = 3'b101; // quotient, unsigned / unsigned
Bit #(3) fnREM    = 3'b110; // remainder, signed % signed
Bit #(3) fnREMU   = 3'b111; // remainder, unsigned % unsigned
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

// pretty print instuction
function Fmt showInst(RawInst inst);
	Fmt ret = $format("");

  Opcode opcode = inst[  6 :  2 ];
  let rd        = inst[ 11 :  7 ];
  let funct3    = inst[ 14 : 12 ];
  let rs1       = inst[ 19 : 15 ];
  let rs2       = inst[ 24 : 20 ];
  let funct7    = inst[ 31 : 25 ];
  let mulDiv    = funct7 == 1; // M-instructions
  let czSel     = unpack(inst[5]) && funct7 == 7; // OpOp and funct7 is 7 -> Zicond extension
  let aluSel    = inst[30]; // select between Add/Sub, Srl/Sra

  Data immI = signExtend(inst[31:20]);
  Data immS = signExtend({ inst[31:25], inst[11:7] });
  Data immB = signExtend({ inst[31], inst[7], inst[30:25], inst[11:8], 1'b0 });
  Data immU = { inst[31:12], 12'b0 };
  Data immJ = signExtend({ inst[31], inst[19:12], inst[20], inst[30:21], 1'b0 });

  case (opcode)
    opOpImm: begin
			ret = case (funct3)
				fnADD: $format("addi");
				fnSLT: $format("slti");
				fnSLTU: $format("sltiu");
				fnAND: $format("andi");
				fnOR: $format("ori");
				fnXOR: $format("xori");
				fnSLL: $format("slli");
				fnSR: (aluSel == 0 ? $format("srli") : $format("srai"));
				default: $format("unsupport OpImm 0x%0x", inst);
			endcase;
			ret = ret + $format(" r%d = r%d ", rd, rs1);
			ret = ret +
			  case (funct3)
			  	fnSLL, fnSR: $format("0x%0x", immI[4:0]); // only low 5 bits for shift
			  	default: $format("0x%0x", immI);
			  endcase;
		end

		opOp: begin
			ret = case (funct3)
				fnADD: (aluSel == 0 ? $format("add") : $format("sub"));
				fnSLT: $format("slt");
				fnSLTU: $format("sltu");
				fnAND: (czSel ? $format("czero.eqz") : $format("and"));
				fnOR: $format("or");
				fnXOR: $format("xor");
				fnSLL: $format("sll");
				fnSR: (aluSel == 0 ? (czSel ? $format("srl") : $format("czero.nez")) : $format("sra"));
			endcase;
			if (mulDiv) begin
			  ret = case (funct3)
          fnMUL    : $format("mul");
          fnMULH   : $format("mulh");
          fnMULHSU : $format("mulhsu");
          fnMULHU  : $format("mulhu");
          fnDIV    : $format("div");
          fnDIVU   : $format("divu");
          fnREM    : $format("rem");
          fnREMU   : $format("remu");
			  endcase;
			end
			ret = ret + $format(" r%d = r%d r%d", rd, rs1, rs2);
		end

		opLui: begin
			ret = $format("lui r%d 0x%0x", rd, immU);
		end

		opAuipc: begin
			ret = $format("auipc r%d 0x%0x", rd, immU);
		end

		opJal: begin
			ret = $format("jal r%d 0x%0x", rd, immJ);
		end

		opJalr: begin
			ret = $format("jalr r%d [r%d 0x%0x]", rd, rs1, immI);
		end

		opBranch: begin
			ret = case(funct3)
				fnBEQ: $format("beq");
				fnBNE: $format("bne");
				fnBLT: $format("blt");
				fnBLTU: $format("bltu");
				fnBGE: $format("bge");
				fnBGEU: $format("bgeu");
				default: $format("unsupport Branch 0x%0x", inst);
			endcase;
			ret = ret + $format(" r%d r%d 0x%0x", rs1, rs2, immB);
		end

		opLoad: begin
			ret = case(funct3)
				fnLW: $format("lw");
        fnLB: $format("lb");
        fnLH: $format("lh");
        fnLBU: $format("lbu");
        fnLHU: $format("lhu");
				default: $format("unsupport Load 0x%0x", inst);
			endcase;
			ret = ret + $format(" r%d = [r%d 0x%0x]", rd, rs1, immI);
		end

		opStore: begin
			ret = case(funct3)
				fnSW: $format("sw");
        fnSB: $format("lb");
        fnSH: $format("lh");
				default: $format("unsupport Store 0x%0x", inst);
			endcase;
			ret = ret + $format(" [r%d 0x%0x] = r%d", rs1, immS, rs2);
		end

		opMiscMem: begin
			ret = case (funct3)
				fnFENCE: $format("fence");
				fnFENCEI: $format("fence.i");
				default: $format("unsupport MiscMem 0x%0x", inst);
			endcase;
		end

		opAmo: begin
			ret = $format("unsupport Amo 0x%0x", inst);
		end

		opSystem: begin
			case (funct3)
				fnCSRRW, fnCSRRS: begin //fnCSRRC, fnCSRRWI, fnCSRRSI, fnCSRRCI: begin
					ret = case(funct3)
						fnCSRRW: $format("csrrw");
						fnCSRRS: $format("csrrs");
					endcase;
					ret = ret + $format(" r%d csr0x%0x r%d", rd, immI[11:0], rs1);
				end

				fnPRIV: begin
					ret = case (truncate(immI))
						//privSCALL: $format("scall");
						default: $format("unsupport System PRIV 0x%0x", inst);
					endcase;
				end

				default: begin
					ret = $format("unsupport System 0x%0x", inst);
				end
			endcase
		end

    opSched: begin
			case (funct3)
				fnTMC: begin
				  ret = $format("tmc");
					ret = ret + $format(" mask: r%d", rs1);
				end
				fnWSPAWN: begin
				  ret = $format("wspawn");
					ret = ret + $format(" count: r%d, pc: r%d", rs1, rs2);
				end
				fnSPLIT: begin
					ret = rs2 == 0 ? $format("split") : $format("split_n");
					ret = ret + $format(" top: r%d, pred: r%d", rd, rs1);
				end
				fnJOIN: begin
				  ret = $format("join");
					ret = ret + $format(" top: r%d", rs1);
				end
				fnBAR: begin
				  ret = $format("bar");
					ret = ret + $format(" barId: r%d, count: r%d", rs1, rs2);
				end
				fnPRED: begin
					ret = rd == 0 ? $format("pred") : $format("pred_n");
					ret = ret + $format(" pred: r%d, restore_mask: r%d", rs1, rs2);
				end
				default: begin
					ret = $format("unsupport Sched 0x%0x", inst);
				end
			endcase
		end

		default: begin
			ret = $format("unsupport 0x%0x", inst);
		end
	endcase

  return ret;

endfunction

