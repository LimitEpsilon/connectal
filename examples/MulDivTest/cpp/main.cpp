#include "MulDivTestIndication.h"
#include "MulDivTestRequest.h"
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <random>

const uint32_t most_negative = 0x80000000UL;

uint16_t rand16() {
    return uint32_t(rand());
}

uint32_t rand32() {
    return ( (uint32_t(rand16()) << 16) |
              uint32_t(rand16()) );
}

MulDivResp refResp(const MulDivReq &req) {
    MulDivResp resp;
    // mul
    uint64_t a = req.mulSign == Unsigned ? uint64_t(uint32_t(req.a)) :
                                           uint64_t(int32_t(req.a));
    uint64_t b = req.mulSign == Signed ? uint64_t(int32_t(req.b)) :
                                         uint64_t(uint32_t(req.b));
    uint64_t prod = a * b;
    resp.productHi = uint32_t(prod >> 32);
    resp.productLo = uint32_t(prod);
    resp.mulTag = req.tag;
    // div
    if(req.divSigned) {
        if(req.a == most_negative && req.b == uint32_t(-1L)) {
            resp.quotient = most_negative;
            resp.remainder = 0;
        } else if(req.b == 0) {
            resp.quotient = uint32_t(0);
            resp.remainder = req.a;
        } else {
            resp.quotient = uint32_t(int32_t(req.a) / int32_t(req.b));
            resp.remainder = uint32_t(int32_t(req.a) % int32_t(req.b));
        }
    } else {
        if(req.b == 0) {
            resp.quotient = uint32_t(0);
            resp.remainder = req.a;
        } else {
            resp.quotient = uint32_t(uint32_t(req.a) / uint32_t(req.b));
            resp.remainder = uint32_t(uint32_t(req.a) % uint32_t(req.b));
        }
    }
    resp.divTag = req.tag;

    return resp;
}

bool sameResp(const MulDivResp &x, const MulDivResp &y) {
    return (x.productHi == y.productHi &&
            x.productLo == y.productLo &&
            x.mulTag == y.mulTag &&
            x.quotient == y.quotient &&
            x.remainder == y.remainder &&
            x.divTag == y.divTag);
}

void printReq(const MulDivReq &r, FILE *fp = stderr) {
    fprintf(fp, "a %016lx, b %016lx, mul sign %d, div sign %d tag %3d\n",
            (long unsigned)(r.a), (long unsigned)(r.b),
            int(r.mulSign), int(r.divSigned), int(r.tag));
}

void printResp(const MulDivResp &r, FILE *fp = stderr) {
    fprintf(fp, "product %016lx %016lx, tag %3d, "
            "quotient %016lx, remainder %016lx, tag %3d\n",
            (long unsigned)(r.productHi),
            (long unsigned)(r.productLo),
            int(r.mulTag),
            (long unsigned)(r.quotient),
            (long unsigned)(r.remainder),
            int(r.divTag));
}

const int test_num = MAX_TEST_NUM;
MulDivReq all_req[test_num];

class MulDivTestIndication : public MulDivTestIndicationWrapper {
private:
    sem_t sem;
    int resp_id;

public:
    MulDivTestIndication(int id) : MulDivTestIndicationWrapper(id), resp_id(0) {
        sem_init(&sem, 0, 0);
    }

    virtual ~MulDivTestIndication() {
        sem_destroy(&sem);
    }

    virtual void resp(MulDivResp r) {
        MulDivResp ref = refResp(all_req[resp_id]);

        fprintf(stderr, "Test %d\n", resp_id);
        fprintf(stderr, "Req : ");
        printReq(all_req[resp_id]);
        fprintf(stderr, "Resp: ");
        printResp(r);
        fprintf(stderr, "Ref : ");
        printResp(ref);
        fprintf(stderr, "\n");

        if(!sameResp(r, ref)) {
            fprintf(stderr, "FAIL!!\n");
            exit(-1);
        }

        resp_id++;
        if(resp_id == test_num) {
            sem_post(&sem);
        }
    }

    void wait() {
        sem_wait(&sem);
    }
};

int main(int argc, char **argv) {
    MulDivTestIndication indication(IfcNames_MulDivTestIndicationH2S);
    MulDivTestRequestProxy reqProxy(IfcNames_MulDivTestRequestS2H);

    // first some corner case tests
    MulDivReq req;
    // overflow
    req.a = most_negative;
    req.b = uint32_t(-1L);
    req.mulSign = Signed;
    req.divSigned = true;
    all_req[0] = req;
    // div by 0
    req.a = most_negative;
    req.b = 0;
    req.mulSign = Unsigned;
    req.divSigned = false;
    all_req[1] = req;
    // div by 0
    req.a = -200;
    req.b = 0;
    req.mulSign = SignedUnsigned;
    req.divSigned = true;
    all_req[2] = req;
    // div by 0
    req.a = 0;
    req.b = 0;
    req.mulSign = Signed;
    req.divSigned = false;
    all_req[3] = req;
    // div by 0
    req.a = 9;
    req.b = 0;
    req.mulSign = Unsigned;
    req.divSigned = true;
    all_req[4] = req;
    // basic siged div
    req.a = 7;
    req.b = 3;
    req.mulSign = SignedUnsigned;
    req.divSigned = true;
    all_req[5] = req;
    // basic siged div
    req.a = -7;
    req.b = 3;
    req.mulSign = SignedUnsigned;
    req.divSigned = true;
    all_req[6] = req;
    // basic siged div
    req.a = 7;
    req.b = -3;
    req.mulSign = SignedUnsigned;
    req.divSigned = true;
    all_req[7] = req;
    // basic siged div
    req.a = -7;
    req.b = -3;
    req.mulSign = SignedUnsigned;
    req.divSigned = true;
    all_req[8] = req;

    // remaining random reqs
    for(int i = 9; i < test_num; i++) {
        req.a = rand32();
        req.b = rand32();
        req.mulSign = MulSign(rand() % 3);
        req.divSigned = bool(rand() % 2);
        all_req[i] = req;
    }

    // fill in tags
    uint32_t tag_mask = (1 << USER_TAG_SIZE) - 1;
    for(uint32_t i = 0; i < test_num; i++) {
        all_req[i].tag = UserTag(i & tag_mask);
    }

    // send req to FPGA
    for(int i = 0; i < test_num; i++) {
        reqProxy.setTest(all_req[i], int(i == (test_num - 1)));
    }

    // wait done
    indication.wait();
    fprintf(stderr, "PASS!!\n");

    return 0;
}
