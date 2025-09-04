#include <cassert>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <semaphore.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/syslimits.h>
#else
#include <limits.h>
#endif

#include "ConnectalProcIndication.h"
#include "ConnectalProcRequest.h"

using namespace std;

static ConnectalProcRequestProxy *connectalProc = 0;
sem_t *done_sem;
static const char *done_sem_name = "/done_sem";

uint32_t print_int = 0;

class ConnectalProcIndication : public ConnectalProcIndicationWrapper {
public:
  virtual void res(uint32_t cycleA, uint32_t valA, uint32_t modelA, uint32_t cycleB, uint32_t valB, uint32_t modelB) {
    fprintf(stderr, "Cycle %d: PortA result: %d, model result: %d\n", cycleA, valA, modelA);
    fprintf(stderr, "Cycle %d: PortB result: %d, model result: %d\n", cycleB, valB, modelB);
  }
  virtual void done(uint32_t msg) { sem_post(done_sem); }
  ConnectalProcIndication(unsigned int id)
      : ConnectalProcIndicationWrapper(id) {}
};

static ConnectalProcIndication *ind = 0;
int main(int argc, char *const *argv) {
  // initialize semaphores
  sem_unlink(done_sem_name);
  if ((done_sem = sem_open(done_sem_name, O_CREAT | O_EXCL, 0644, 0)) ==
      SEM_FAILED) {
    fprintf(stderr, "failed to initialize done_sem\n");
    exit(1);
  }

  connectalProc =
      new ConnectalProcRequestProxy(IfcNames_ConnectalProcRequestS2H);
  ind = new ConnectalProcIndication(IfcNames_ConnectalProcIndicationH2S);

  connectalProc->start();
  sem_wait(done_sem);
  connectalProc->finish();
  return 0;
}
