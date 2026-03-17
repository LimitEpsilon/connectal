#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <unistd.h>
#include "loadelf.h"
#ifdef __APPLE__
#include <sys/syslimits.h>
#else
#include <limits.h>
#endif

typedef enum {
  SignalDone   = 0,
  ExitCode     = 1,
  PrintChar    = 2,
  TellState    = 3
} CpuToHostType;

typedef enum {
  START_LOAD_DATA   = 0,
  DO_LOAD_DATA      = 1,
  START_LOAD_KERNEL = 2,
  DO_LOAD_KERNEL    = 3,
  START_EXEC        = 4,
  DO_EXEC           = 5,
  DOWNLOAD_DATA     = 6
} ProcState;

#ifdef __cplusplus
extern "C" {
#endif

void vx_upload_data_init(void);
uint64_t vx_upload_data(void);
uint32_t vx_kernel_arg(void);
uint32_t vx_download_data_req(void);
void vx_download_data_resp(uint32_t addr, uint32_t data);
void vx_validate(void);

#ifdef __cplusplus
}
#endif

static const char *server_path = "./vx_socket.server";
static const char *client_path = "./vx_socket.client";
static int server_sock = -1;
static int client_sock = -1;

static void safe_recv(uint64_t *msg, int lineno) {
  if (recv(client_sock, msg, sizeof(*msg), 0) == -1) {
    fprintf(stderr, "CLIENT: Error on line %d\n", lineno);
    close(client_sock);
    exit(1);
  }
}

static void safe_send(uint64_t *data, int lineno) {
  if (send(client_sock, data, sizeof(*data), 0) == -1) {
    fprintf(stderr, "CLIENT: Error on line %d\n", lineno);
    close(client_sock);
    exit(1);
  }
}

static uint32_t get_type(uint64_t msg) {
  return (msg >> 32) & 3;
}

int main(int argc, char *const *argv) {
  char pathbuf[PATH_MAX] = {'\0'};
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <path to kernel binary>\n", argv[0]);
    exit(1);
  }

  if (open(client_path, O_CREAT, 0666) == -1) {
    fprintf(stderr, "CLIENT: Error creating socket file: %s\n", strerror(errno));
    exit(1);
  }

  client_sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (client_sock == -1) {
    fprintf(stderr, "CLIENT: Socket error: %s\n", strerror(errno));
    exit(1);
  }

  struct sockaddr_un server_addr, client_addr;
  memset(&server_addr, 0, sizeof(server_addr));
  memset(&client_addr, 0, sizeof(client_addr));

  if (realpath(server_path, pathbuf) == NULL) {
    fprintf(stderr, "CLIENT: server_path resolution error: %s\n", strerror(errno));
    close(client_sock);
    exit(1);
  }
  server_addr.sun_family = AF_UNIX;
  strcpy(server_addr.sun_path, pathbuf);

  if (realpath(client_path, pathbuf) == NULL) {
    fprintf(stderr, "CLIENT: client_path resolution error: %s\n", strerror(errno));
    close(client_sock);
    exit(1);
  }
  client_addr.sun_family = AF_UNIX;
  strcpy(client_addr.sun_path, pathbuf);
  int len = sizeof(client_addr);

  unlink(pathbuf);
  if (bind(client_sock, (struct sockaddr *)&client_addr, len) == -1) {
    fprintf(stderr, "CLIENT: Client binding error. %s\n", strerror(errno));
    close(client_sock);
    exit(1);
  }

  if (connect(client_sock, (struct sockaddr*)&server_addr, len) == -1) {
    fprintf(stderr, "CLIENT: Connect error. %s\n", strerror(errno));
    close(client_sock);
    exit(1);
  }

  fprintf(stderr, "CLIENT: Connected to driver code.\n");

  uint64_t msg = 0;
  uint32_t type = 0;
  uint32_t msg_data = 0;
  uint64_t data = 0;
  uint32_t wasCycles = 0;

  safe_recv(&msg, __LINE__);
  type = get_type(msg);
  msg_data = (uint32_t)msg;
  if (type != TellState) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  if (msg_data != START_LOAD_DATA) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  vx_upload_data_init();
  while ((data = vx_upload_data()) >> 32 != 1) {
    safe_send(&data, __LINE__);
    safe_recv(&msg, __LINE__); // ACK
  }
  safe_send(&data, __LINE__);
  safe_recv(&msg, __LINE__); // ACK

  safe_recv(&msg, __LINE__);
  type = get_type(msg);
  msg_data = (uint16_t)msg;
  if (type != TellState) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  if (msg_data != START_LOAD_KERNEL) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  msg = vx_upload_kernel_init(argv[1]);
  if (msg != 0) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }
  while ((data = vx_upload_kernel()) >> 32 != 1) {
    safe_send(&data, __LINE__);
    safe_recv(&msg, __LINE__); // ACK
  }
  data = data | vx_kernel_arg();
  safe_send(&data, __LINE__);
  safe_recv(&msg, __LINE__); // ACK

  safe_recv(&msg, __LINE__);
  type = get_type(msg);
  msg_data = (uint16_t)msg;
  if (type != TellState) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  if (msg_data != START_EXEC) {
    fprintf(stderr, "Error, %d\n", __LINE__);
    goto cleanup_label;
  }

  do {
    safe_recv(&msg, __LINE__);
    type = get_type(msg);
    msg_data = (uint32_t)msg;
    if (type == PrintChar)
      fprintf(stderr, "%c", (char)msg_data);
    else if (type == SignalDone) {
      if (wasCycles) {
        wasCycles = 0;
        fprintf(stderr, "Instructions: %u ", msg_data);
      } else {
        wasCycles = 1;
        fprintf(stderr, "Cycles: %u ", msg_data);
      }
    }
  } while (type != ExitCode);

  if (msg_data == 0)
    fprintf(stderr, "PASSED\n");
  else {
    fprintf(stderr, "FAILED: exit code = %d\n", (int)data);
    goto cleanup_label;
  }

  while ((data = vx_download_data_req()) != 1) {
    safe_send(&data, __LINE__);
    safe_recv(&msg, __LINE__); // download data
    vx_download_data_resp((uint32_t)data, msg);
  }
  safe_send(&data, __LINE__);
  safe_recv(&msg, __LINE__); // ACK

  data = (uint64_t)-1; // signal the server that I am done
  safe_send(&data, __LINE__);
  vx_validate();

cleanup_label:
  close(client_sock);
  remove(pathbuf);
  return 0;
}

