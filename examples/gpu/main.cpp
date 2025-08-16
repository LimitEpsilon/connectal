#include <cassert>
#include <cstdio>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <list>
#include <semaphore.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include "ConnectalProcIndication.h"
#include "ConnectalProcRequest.h"

using namespace std;

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
  printf("Start testbench:\n");

  // initialize semaphores
  sem_unlink(done_sem_name);
  if ((done_sem = sem_open(done_sem_name, O_CREAT | O_EXCL, 0644, 0)) ==
      SEM_FAILED) {
    fprintf(stderr, "failed to initialize done_sem\n");
    return -1;
  }
  sem_unlink(meminit_sem_name);
  if ((meminit_sem = sem_open(meminit_sem_name, O_CREAT | O_EXCL, 0644, 0)) ==
      SEM_FAILED) {
    fprintf(stderr, "failed to initialize meminit_sem\n");
    return -1;
  }
  fflush(stdout);

  connectalProc =
      new ConnectalProcRequestProxy(IfcNames_ConnectalProcRequestS2H);
  ind = new ConnectalProcIndication(IfcNames_ConnectalProcIndicationH2S);

  // initialize memory
  char cwd[1024];
  const char *mem = strcat(getcwd(cwd, sizeof(cwd)), "/mem.vmh");
  FILE *fd = fopen(mem, "r");
  if (fd == NULL) {
    fprintf(stderr, "Cannot find %s\n", mem);
    return -1;
  }
  uint32_t addr = 0;
  uint32_t data = 0;
  int c;
  int skip_line = 0;
  int empty_line = 1;
  while ((c = getc(fd)) != EOF) {
    if (skip_line) {
      if (c == '\n' || c == '\r') {
        empty_line = 1;
        skip_line = 0;
      }
    } else if (c == '\n' || c == '\r') {
      if (!empty_line) {
        connectalProc->hostToCpu(addr, data, 0, 0);
        sem_wait(meminit_sem);
        data = 0;
        addr += 4;
      }
    } else {
      empty_line = 0;
      if ('0' <= c && c < '0' + 10) {
        data = (data << 4) | (c - '0');
      } else if ('a' <= c && c < 'a' + 6) {
        data = (data << 4) | (c - 'a' + 10);
      } else {
        skip_line = 1;
      }
    }
  }
  connectalProc->hostToCpu(0, 0, 0, 1);
  printf("Processor started");
  fflush(stdout);

  // Now the processor is running we are waiting for it to be done
  sem_wait(done_sem);
  return 0;
}
