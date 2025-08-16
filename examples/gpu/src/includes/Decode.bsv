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
  Opcode opcode = inst[  6 :  0 ];
  RIndx rd      = inst[ 11 :  7 ];
  let funct3    = inst[ 14 : 12 ];
  RIndx rs1     = inst[ 19 : 15 ];
  RIndx rs2     = inst[ 24 : 20 ];
  // let succ      = inst[ 23 : 20 ];
  // let pred      = inst[ 27 : 24 ];
  // let fm        = inst[ 31 : 28 ];
  let funct7    = inst[ 31 : 25 ];
  let mulDiv    = funct7 == 1; // M-instructions
  let czSel     = unpack(opcode[5]) && funct7 == 7; // OpOp and funct7 is 7 -> Zicond extension
  let aluSel    = inst[30]; // select between Add/Sub, Srl/Sra

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
    opLoad: case (funct3) // only support LW, rd <- M[rs1 + immI]; pc <- pc + 4
      fnLW: Ld;
      fnLB, fnLH, fnLBU, fnLHU: LdMask;
      default: Unsupported;
    endcase
    opStore: case (funct3) // only support SW, M[rs1 + immI] <- rs2; pc <- pc + 4
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

  let aluValid = { opcode[6], opcode[4:0] } == { opOp[6], opOp[4:0] };  // opOp or opImm

  let aluFunc =
    aluValid ?
    case (funct3)
      fnADD:  unpack(opcode[5]) && unpack(aluSel) ? Sub : Add;
      fnSLT:  Slt;
      fnSLTU: Sltu;
      fnAND:  czSel ? Ceqz : And;
      fnOR:   Or;
      fnXOR:  Xor;
      fnSLL:  Sll;
      fnSR:   unpack(aluSel) ? Sra : (czSel ? Cnez : Srl);
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

  let conv = { opcode[3:0], funct3[1] } == { opSched[3:0], fnSPLIT[1] }; // split/join are the only instructions with funct3 = x1x among the scheduling instructions

  let immValid = opcode[5:0] != opOp[5:0]; // opOp or opSystem, used to select the second argument to give to the *alu*

  let imm = case (opcode)
    opLui, opAuipc: immU;
    opJal: immJ;
    opBranch: immB;
    opStore: immS;
    default: immI;
  endcase;

  let dInst = DecodedInst {
    iType: iType,
    aluFunc: aluFunc,
    mFunc: mFunc,
    brFunc: brFunc, // only used by branch instructions
    conv: conv,
    predN: rd != 0 && rs2 != 0, // if pred, rs2 != 0. if split, rd != 0
    dst: rd,
    src1: opcode == opLui ? 0 : rs1,
    src2: rs2,
    csr: truncate(immI),
    immValid: immValid,
    imm: imm
  };

  return dInst;
endfunction

