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

// forward declaration of function defined in loadelf.cpp
int load_elf(ConnectalProcRequestProxy *proc, sem_t *sem, const char *name);

static ConnectalProcRequestProxy *connectalProc = 0;
sem_t *done_sem;
sem_t *meminit_sem;
static const char *done_sem_name = "/done_sem";
static const char *meminit_sem_name = "/meminit_sem";

uint32_t print_int = 0;

class ConnectalProcIndication : public ConnectalProcIndicationWrapper {
public:
  virtual void sendMessage(uint32_t msg) {
    uint32_t type = msg >> 16;
    uint32_t data = msg & ((1 >> 16) - 1);
    if (type == 0) {
      if (data == 0) {
        fprintf(stderr, "PASSED\n");
      } else {
        fprintf(stderr, "FAILED: exit code = %d\n", data);
      }
      sem_post(done_sem);
    } else if (type == 1) {
      fprintf(stderr, "%c", (char)data);
    } else if (type == 2) {
      print_int = uint32_t(data);
    } else if (type == 3) {
      print_int |= uint32_t(data) << 16;
      fprintf(stderr, "%d", print_int);
    }
  }
  virtual void wroteWord(uint32_t msg) { sem_post(meminit_sem); }
  ConnectalProcIndication(unsigned int id)
      : ConnectalProcIndicationWrapper(id) {}
};

static ConnectalProcIndication *ind = 0;
int main(int argc, char *const *argv) {
  if (argc < 2) {
    fprintf(stderr,
            "Pass in the filename of the elf file to be loaded onto the GPU\n");
    exit(1);
  }
  printf("Start testbench:\n");

  // initialize semaphores
  sem_unlink(done_sem_name);
  if ((done_sem = sem_open(done_sem_name, O_CREAT | O_EXCL, 0644, 0)) ==
      SEM_FAILED) {
    fprintf(stderr, "failed to initialize done_sem\n");
    exit(1);
  }
  sem_unlink(meminit_sem_name);
  if ((meminit_sem = sem_open(meminit_sem_name, O_CREAT | O_EXCL, 0644, 0)) ==
      SEM_FAILED) {
    fprintf(stderr, "failed to initialize meminit_sem\n");
    exit(1);
  }
  fflush(stdout);

  connectalProc =
      new ConnectalProcRequestProxy(IfcNames_ConnectalProcRequestS2H);
  ind = new ConnectalProcIndication(IfcNames_ConnectalProcIndicationH2S);

  // initialize memory
  char pathbuf[PATH_MAX];
  const char *mem = realpath(argv[1], pathbuf);
  load_elf(connectalProc, meminit_sem, mem);
  connectalProc->hostToCpu(0, 0, 0, 1);
  printf("Processor started\n");
  fflush(stdout);

  // Now the processor is running we are waiting for it to be done
  sem_wait(done_sem);
  return 0;
}
