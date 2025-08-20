/*

Copyright (C) 2012

Arvind <arvind@csail.mit.edu>
Derek Chiou <derek@ece.utexas.edu>
Muralidaran Vijayaraghavan <vmurali@csail.mit.edu>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import Types::*;
import ProcTypes::*;
import Vector::*;

(* noinline *)
function DecodedInst decode(RawInst inst);
  Opcode opcode = inst[  6 :  2 ];
  RIndx rd      = inst[ 11 :  7 ];
  let funct3    = inst[ 14 : 12 ];
  RIndx rs1     = inst[ 19 : 15 ];
  RIndx rs2     = inst[ 24 : 20 ];
  // let succ      = inst[ 23 : 20 ];
  // let pred      = inst[ 27 : 24 ];
  // let fm        = inst[ 31 : 28 ];
  let funct7    = inst[ 31 : 25 ];
  let mulDiv    = funct7 == 1; // M-instructions
  Bool isOp     = unpack(inst[5]); // distinguish between opOp and opImm
  let czSel     = isOp && funct7 == 7; // OpOp and funct7 is 7 -> Zicond extension
  Bool aluSel   = unpack(inst[30]); // select between Add/Sub, Srl/Sra

  Data immI = signExtend({ inst[31:20] });
  Data immS = signExtend({ inst[31:25], inst[11:7] });
  Data immB = signExtend({ inst[31], inst[7], inst[30:25], inst[11:8], 1'b0 });
  Data immU = signExtend({ inst[31:12], 12'b0 });
  Data immJ = signExtend({ inst[31], inst[19:12], inst[20], inst[30:21], 1'b0 });

  let iType = case (opcode)
    opOpImm: Alu; // rd <- op rs1 immI; pc <- pc + 4
    opOp: mulDiv ? MulDiv : Alu; // rd <- op rs1 rs2; pc <- pc + 4
    opLui: Alu; // rd <- zero + immU; pc <- pc + 4
    opAuipc: Auipc; // rd <- pc + immU;  pc <- pc + 4
    opJal: J; // rd <- pc + 4; pc <- pc + immJ
    opJalr: Jr; // rd <- pc + 4; pc <- rs1 + immI
    opBranch: case (funct3) // pc <- compare rs1 rs2 ? pc + immI : pc + 4
      fnBEQ, fnBNE, fnBLT, fnBLTU, fnBGE, fnBGEU: Br;
      default: Unsupported;
    endcase
    opLoad: case (funct3) // rd <- M[rs1 + immI]; pc <- pc + 4
      fnLW: Ld;
      fnLB, fnLH, fnLBU, fnLHU: LdMask;
      default: Unsupported;
    endcase
    opStore: case (funct3) // M[rs1 + immI] <- rs2; pc <- pc + 4
      fnSW: St;
      fnSB, fnSH: StMask;
      default: Unsupported;
    endcase
    // LR SC not implemented
    opMiscMem: case (funct3)
      fnFENCE: Fence;
      default: Unsupported;
    endcase
    opSystem: case (funct3) // CSRRC(I) CSRRWI CSRRSI SCALL not implemented
      fnCSRRW: // csr <- rs1; pc <- pc + 4
        // only support rd = 0 (no read of csr)
        rd == 0 ? Csrw : Unsupported;
      fnCSRRS: // rd <- csr; pc <- pc + 4
        // only support rs1 = 0 (no write to csr)
        rs1 == 0 ? Csrr : Unsupported;
      default: Unsupported;
    endcase
    opSched: case (funct3)
      fnTMC, fnWSPAWN, fnSPLIT, fnJOIN, fnBAR, fnPRED: Sched;
      default: Unsupported;
    endcase
    default: Unsupported;
  endcase;

  let aluValid = { opcode[4], opcode[2:0] } == { opOp[4], opOp[2:0] };  // opOp or opImm

  let aluFunc =
    aluValid ?
    case (funct3)
      fnADD:  isOp && aluSel ? Sub : Add;
      fnSLT:  Slt;
      fnSLTU: Sltu;
      fnAND:  czSel ? Ceqz : And;
      fnOR:   Or;
      fnXOR:  Xor;
      fnSLL:  Sll;
      fnSR:   aluSel ? Sra : (czSel ? Cnez : Srl);
    endcase :
    Add;

  MFunc mFunc = unpack(funct3);

  let brFunc = case (funct3)
    fnBEQ:   Eq;
    fnBNE:   Neq;
    fnBLT:   Lt;
    fnBLTU:  Ltu;
    fnBGE:   Ge;
    fnBGEU:  Geu;
    default: NT;
  endcase;

  // split/join are the only instructions with funct3 = x1x among the scheduling instructions
  let conv = { opcode[1:0], funct3[1] } == { opSched[1:0], fnSPLIT[1] };

  // used to select the second argument to give to the *alu*
  // opSched doesn't go through the alu, so it's okay
  let immValid = opcode[3:0] != opOp[3:0];
  let imm = case (opcode)
    opLui, opAuipc: immU;
    opJal: immJ;
    opBranch: immB;
    opStore: immS;
    default: immI;
  endcase;

  let dstValid = opcode != opBranch && opcode != opStore && opcode != opSched;
  let src1Valid = opcode != opLui && opcode != opAuipc && opcode != opJal; // immU or immJ
  let src2Valid = opcode == opOp || !dstValid;

  let dInst = DecodedInst {
    iType: iType,
    aluFunc: aluFunc,
    mFunc: mFunc,
    brFunc: brFunc, // only used by branch instructions
    conv: conv,
    predN: rd != 0 && rs2 != 0, // if pred, rs2 != 0. if split, rd != 0
    dst: dstValid ? rd : 0,
    src1: src1Valid ? rs1 : 0,
    src2: src2Valid ? rs2 : 0,
    csr: truncate(immI),
    immValid: immValid,
    imm: imm
  };

  return dInst;
endfunction

