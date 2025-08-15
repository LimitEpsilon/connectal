import Vector::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;

import Fifo::*;
import CoalTree::*;

typedef Bit#(8) Byte;

// a = h + w, where the width of the memory is 2ʷ bytes
// one word = d bytes, assume that the memory is wide enough to support one word in one cycle
// that is, d ≤ 2ʷ
typedef struct {
  Bool write;
  Vector#(n, Bit#(a)) addresses; // byte addresses
  Vector#(n, Bit#(TMul#(d, 8))) datas;
  Bit#(d) byteen;
  Bit#(n) mask;
} VecMemoryRequest#(numeric type n, numeric type a, numeric type d)
deriving (Bits, Eq, FShow);

// the payload to be merged in the CoalTree: (2ʷ + d) bytes, supporting unaligned accesses
typedef
  Vector#(TAdd#(TExp#(w), d), Maybe#(Byte))
MemoryPayload#(numeric type w, numeric type d);

// preprocess memory requests
function MemoryPayload#(w, subd) mkMemoryPayload
  (Bit#(d) byteen, Bit#(w) offset, Vector#(d, Byte) data)
  provisos (Add#(1, subd, d), Add#(1, subw, TExp#(w)), Add#(subw, d, TAdd#(TExp#(w), subd)));

  let shamt = {1'b0, offset};
  Integer wd = valueOf(TLog#(TAdd#(TExp#(w), subd))); // = 1 + valueOf(w) if 0 < d ≤ 2ʷ

  function Maybe#(t) mask(Bool v, t x) = v ? tagged Valid x : tagged Invalid;
  Vector#(d, Maybe#(Byte)) odata = zipWith(mask, unpack(byteen), data);
  Vector#(TAdd#(TExp#(w), subd), Maybe#(Byte)) extended = append(odata, unpack(0));
  Vector#(TAdd#(TExp#(w), subd), Maybe#(Byte)) datas = rotateBy(extended, unpack(shamt[wd-1 : 0]));

  return datas;
endfunction

typedef struct {
  Vector#(n, Bit#(TMul#(d, 8))) datas;
} VecMemoryResponse#(numeric type n, numeric type d)
deriving (Bits, Eq, FShow);

typedef Server#(VecMemoryRequest#(n, a, d), VecMemoryResponse#(n, d))
  VecMemoryServer#(numeric type n, numeric type a, numeric type d);

// dataword: d bytes, memory height: 2ʰ, memory width: 2ʷ bytes, number of lanes: n
// Currently, we assume d = 4 (32 bit word), w = 6 (512 bit DRAM interface)
module mkVecMemoryServer#(MemoryServer#(h, w8) m) (VecMemoryServer#(n, a, d) ifc)
  provisos (
    Add#(1, subd, d), Add#(1, subw, TExp#(w)),
    Add#(subd, _, TExp#(w)), Add#(subw, d, TAdd#(TExp#(w), subd)),
    Add#(h, w, a), Mul#(TExp#(w), 8, w8), Div#(w8, 8, TExp#(w)),
    Coalescer#(n, h, MemoryPayload#(w, subd))
  );

  function Maybe#(t) merge(Maybe#(t) x, Maybe#(t) y) = isValid(x) ? x : y;

  // CoalReq → CoalResp → MemoryRequest → MemoryResponse → enq to out
  CoalTree#(n, h, MemoryPayload#(w, subd)) c <- mkCoalTree(zipWith(merge));
  // final destination
  Vector#(n, FIFOF#(Vector#(d, Byte))) out <- replicateM(mkLFIFOF);
  Fifo#(2, Bit#(n)) outMasks <- mkPipelineFifo(True, True);

  // enq at CoalReq, deq at MemoryResponse
  Vector#(n, Fifo#(2, Bit#(w))) offsets <- replicateM(mkPipelineFifo(False, False)); // unguarded, stores address[w-1 : 0]

  // enq at CoalReq, deq at CoalResp
  Reg#(Bool) lastEpoch <- mkReg(False);
  Reg#(Bool) lastWrite <- mkReg(False);
  Fifo#(TLog#(n), Bool) writes <- mkPipelineFifo(True, False); // enq guarded, stores write

  // enq at CoalResp, deq at MemoryRequest
  Reg#(Maybe#(MemoryRequest#(h, w8))) unalignedReq <- mkReg(tagged Invalid); // outstanding unaligned request

  // enq at MemoryRequest, deq at MemoryResponse
  FIFOF#(Bit#(n)) respMasks <- mkLFIFOF;
  FIFOF#(Bool) unalignedResp <- mkUGLFIFOF; // synchronized with respMasks
  Reg#(Bool) needWait <- mkReg(False); // need to wait for unaligned response

  // enq at MemoryResponse, deq at enq to out
  Reg#(Vector#(TExp#(w), Byte)) waitResp <- mkReg(unpack(0)); // aligned responses that are waiting

  (* fire_when_enabled *)
  rule do_mem_req;
    if (unalignedReq matches tagged Valid .req) begin
      m.request.put(req);
      unalignedReq <= tagged Invalid;
    end else begin
      let r = c.first;
      let address = r.kv.key;
      let byteen = map(isValid, r.kv.val);
      let datas = map(fromMaybe(0), r.kv.val);

      // determine write
      let curE = c.getEpoch;
      let epochEq = lastEpoch == curE;
      let write = epochEq ? lastWrite : writes.first;

      Vector#(TExp#(w), Bool) alignedByteen = take(byteen);
      Vector#(TExp#(w), Byte) alignedData = take(datas);

      Vector#(subd, Bool) unalignedByteen_ = takeTail(byteen);
      Vector#(TExp#(w), Bool) unalignedByteen = append(unalignedByteen_, replicate(False));
      Vector#(subd, Byte) unalignedData_ = takeTail(datas);
      Vector#(TExp#(w), Byte) unalignedData = append(unalignedData_, replicate(0));

      Bool unaligned = any(id, unalignedByteen_);

      MemoryRequest#(h, w8) alignedR = MemoryRequest {
        write: write,
        byteen: pack(alignedByteen),
        address: address,
        data: pack(alignedData)
      };
      MemoryRequest#(h, w8) unalignedR = MemoryRequest {
        write: write,
        byteen: pack(unalignedByteen),
        address: address + 1,
        data: pack(unalignedData)
      };

      m.request.put(alignedR);
      if (unaligned) unalignedReq <= tagged Valid unalignedR;
      if (!write) begin
        respMasks.enq(r.mask);
        unalignedResp.enq(unaligned);
      end
      if (!epochEq) begin
        lastEpoch <= curE;
        lastWrite <= write;
        writes.deq;
      end
      c.deq;
    end
  endrule

  (* fire_when_enabled *)
  rule do_mem_resp;
    let resp <- m.response.get;
    let respMask = respMasks.first;
    let unaligned = unalignedResp.first;

    Vector#(TExp#(w), Byte) respData = unpack(resp.data);
    Vector#(TExp#(w), Byte) alignedData = needWait ? waitResp : respData;
    Vector#(subd, Byte) unalignedData = take(respData);
    let data = append(alignedData, unalignedData);

    Integer wd = valueOf(TLog#(TAdd#(TExp#(w), subd))); // = 1 + valueOf(w) if 0 < d ≤ 2ʷ

    function Vector#(d, Byte) genOut(Integer i);
      let offsetBit = {1'b0, offsets[i].first};
      UInt#(TLog#(TAdd#(TExp#(w), subd))) offset = unpack(offsetBit[wd-1 : 0]);
      return take(reverse(rotateBy(reverse(data), offset))); // rotate left
    endfunction

    if (needWait || !unaligned) begin
      needWait <= False;
      for (Integer i = 0; i < valueOf(n); i = i + 1)
        if (respMask[i] == 1) begin
          out[i].enq(genOut(i));
          offsets[i].deq;
        end
      respMasks.deq;
      unalignedResp.deq;
    end else begin
      needWait <= True;
      waitResp <= respData;
    end
  endrule

  interface Put request;
    method Action put(VecMemoryRequest#(n, a, d) vReq);
      match VecMemoryRequest {
        write: .write,
        addresses: .addresses,
        datas: .datas,
        byteen: .byteen,
        mask: .mask
      } = vReq;

      function Maybe#(KV#(h, MemoryPayload#(w, subd))) genReq(Integer i);
        Bit#(w) offset = truncate(addresses[i]);
        Vector#(d, Byte) data = unpack(datas[i]);
        KV#(h, MemoryPayload#(w, subd)) kv = KV {
          key: truncateLSB(addresses[i]),
          val: mkMemoryPayload(byteen, offset, data)
        };
        return mask[i] == 1 ? tagged Valid kv : tagged Invalid;
      endfunction

      CoalReq#(n, h, MemoryPayload#(w, subd)) cReq = genWith(genReq);

      c.enq(cReq);
      writes.enq(write);
      if (!write) begin
        outMasks.enq(mask);
        for (Integer i = 0; i < valueOf(n); i = i + 1)
          if (mask[i] == 1) offsets[i].enq(truncate(addresses[i]));
      end
    endmethod
  endinterface

  interface Get response;
    method ActionValue#(VecMemoryResponse#(n, d)) get;
      let outMask = outMasks.first;
      Vector#(n, Bit#(TMul#(d, 8))) ret = replicate(0);
      for (Integer i = 0; i < valueOf(n); i = i + 1)
        if (outMask[i] == 1) begin
          ret[i] = pack(out[i].first);
          out[i].deq;
        end
      outMasks.deq;
      return VecMemoryResponse {datas: ret};
    endmethod
  endinterface
endmodule

// TODO:: module mkVecBankedMemoryServer(
//   Vector#(b, MemoryServer#(a, d)) banks,
//   function Bit#(lb) dec_bank(Bit#(la) addr),
//   VecMemoryServer#(n, a, d) ifc
// ) provisos (Log#(a, la), Log#(b, lb));

// TODO:: module mkBurstMemoryServer(
// Given a stream of sorted MemoryRequest#(a, d) and given a memory that
// supports burst read/writes of (m * d) bits (i.e. MemoryServer#(a, md)),
// detect memory requests that fits within a burst.
// If it is a write, use the byteen field of MemoryRequest#(a, m * d)
// to select the valid write data
// ) provisos (Mul#(m, d, md));

