#include <cstdio>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
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
static const char *server_path = "./vx_socket.server";
static int server_sock = -1;
static int client_sock = -1;

static void safe_recv(uint64_t *data, int lineno) {
  if (recv(client_sock, data, sizeof(*data), 0) == -1) {
    fprintf(stderr, "SERVER: Error on line %d\n", lineno);
    close(server_sock);
    close(client_sock);
    exit(1);
  }
}

static void safe_send(uint32_t *msg, int lineno) {
  if (send(client_sock, msg, sizeof(*msg), 0) == -1) {
    fprintf(stderr, "SERVER: Error on line %d\n", lineno);
    close(server_sock);
    close(client_sock);
    exit(1);
  }
}

class ConnectalProcIndication : public ConnectalProcIndicationWrapper {
public:
  virtual void sendMessage(uint32_t msg) {
    safe_send(&msg, __LINE__);
  }
  virtual void sendData(uint32_t data) {
    safe_send(&data, __LINE__);
  }
  ConnectalProcIndication(unsigned int id)
      : ConnectalProcIndicationWrapper(id) {}
};

static ConnectalProcIndication *ind = 0;
int main(int argc, char *const *argv) {
  char pathbuf[PATH_MAX] = {'\0'};
  if (argc < 3) {
    fprintf(stderr, "Usage: %s <name of host binary> <arguments to host binary>\n", argv[0]);
    exit(1);
  }

  if (open(server_path, O_CREAT, 0666) == -1) {
    fprintf(stderr, "SERVER: Error creating socket file: %s\n", strerror(errno));
    exit(1);
  }

  server_sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (server_sock == -1) {
    fprintf(stderr, "SERVER: Socket error: %s\n", strerror(errno));
    exit(1);
  }

  struct sockaddr_un server_addr, client_addr;
  memset(&server_addr, 0, sizeof(server_addr));
  memset(&client_addr, 0, sizeof(client_addr));

  if (realpath(server_path, pathbuf) == NULL) {
    fprintf(stderr, "SERVER: server_path resolution error: %s\n", strerror(errno));
    close(server_sock);
    exit(1);
  }
  server_addr.sun_family = AF_UNIX;
  strcpy(server_addr.sun_path, pathbuf);
  int len = sizeof(server_addr);

  unlink(pathbuf);
  if (bind(server_sock, (struct sockaddr *)&server_addr, len) == -1) {
    fprintf(stderr, "SERVER: Server binding error. %s\n", strerror(errno));
    close(server_sock);
    exit(1);
  }

  if (listen(server_sock, 1) == -1) {
    fprintf(stderr, "SERVER: Listen error: %s\n", strerror(errno));
    close(server_sock);
    exit(1);
  }

  pid_t pid;

  pid = fork();

  if (pid < 0) {
    fprintf(stderr, "Failed to fork, %s\n", strerror(errno));
    close(server_sock);
    exit(1);
  }

  if (pid == 0) {
    char *env[] = {NULL};

    if (realpath(argv[1], pathbuf) == NULL) {
      fprintf(stderr, "Failed to execute %s, %s\n", argv[1], strerror(errno));
      exit(1);
    }

    execve(pathbuf, argv + 1, env);

    fprintf(stderr, "Failed to execute %s, %s\n", argv[1], strerror(errno));
    exit(1);
  }

  client_sock = accept(server_sock, (struct sockaddr *)&client_addr, (socklen_t*)&len);
  if (client_sock == -1) {
    fprintf(stderr, "SERVER: Accept error: %s\n", strerror(errno));
    close(server_sock);
    close(client_sock);
    exit(1);
  }

  connectalProc = new ConnectalProcRequestProxy(IfcNames_ConnectalProcRequestS2H);
  ind = new ConnectalProcIndication(IfcNames_ConnectalProcIndicationH2S);

  uint64_t loaded = (uint64_t)-1;
  do {
    safe_recv(&loaded, __LINE__);
    if (loaded != (uint64_t)-1)
      connectalProc->hostToProc(loaded);
  } while (loaded != (uint64_t)-1);

  close(server_sock);
  close(client_sock);
  remove(pathbuf);
  return 0;
}
