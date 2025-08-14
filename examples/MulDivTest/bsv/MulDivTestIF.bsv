`include "ConnectalProjectConfig.bsv"

typedef `USER_TAG_SIZE UserTagSz;
typedef Bit#(UserTagSz) UserTag;

typedef enum {
    Signed,
    Unsigned,
    SignedUnsigned
} MulSign deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(32) a;
    Bit#(32) b;
    MulSign mulSign;
    Bool divSigned;
    UserTag tag;
} MulDivReq deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(32) productHi;
    Bit#(32) productLo;
    UserTag mulTag;
    Bit#(32) quotient;
    Bit#(32) remainder;
    UserTag divTag;
} MulDivResp deriving(Bits, Eq, FShow);

interface MulDivTestRequest;
    method Action setTest(MulDivReq r, Bool last);
endinterface

interface MulDivTestIndication;
    method Action resp(MulDivResp r);
endinterface
