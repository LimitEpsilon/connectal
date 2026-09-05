#include <iostream>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <limits>
#include "mem_alloc.h"

// defined in common.h for each test case
#define TYPE float
#define NUM_LOADS 8

#ifndef MSTRESS_NUM_WARPS
#define MSTRESS_NUM_WARPS 16
#endif

static_assert(MSTRESS_NUM_WARPS > 0, "MSTRESS_NUM_WARPS must be positive");

typedef struct {
  uint32_t num_tasks;
  uint32_t size;
  uint32_t stride;
  uint64_t src0_addr;
  uint64_t src1_addr;
  uint64_t dst_addr;
} kernel_arg_t;

MemoryAllocator global_mem =
  MemoryAllocator(ALLOC_BASE_ADDR, GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR, MEM_PAGE_SIZE, CACHE_BLOCK_SIZE);

// start of main.cpp
union Float_t {
    float f;
    int   i;
    struct {
        uint32_t man  : 23;
        uint32_t exp  : 8;
        uint32_t sign : 1;
    } parts;
};

inline float fround(float x, int32_t precision = 8) {
  auto power_of_10 = std::pow(10, precision);
  return std::round(x * power_of_10) / power_of_10;
}

inline bool almost_equal_eps(float a, float b, int ulp = 128) {
  auto eps = std::numeric_limits<float>::epsilon() * (std::max(fabs(a), fabs(b)) * ulp);
  auto d = fabs(a - b);
  if (d > eps) {
    std::cout << "*** almost_equal_eps: d=" << d << ", eps=" << eps << std::endl;
    return false;
  }
  return true;
}

inline bool almost_equal_ulp(float a, float b, int32_t ulp = 6) {
  Float_t fa{a}, fb{b};
  auto d = std::abs(fa.i - fb.i);
  if (d > ulp) {
    std::cout << "*** almost_equal_ulp: a=" << a << ", b=" << b << ", ulp=" << d << ", ia=" << std::hex << fa.i << ", ib=" << fb.i << std::endl;
    return false;
  }
  return true;
}

inline bool almost_equal(float a, float b) {
  if (a == b)
    return true;
  /*if (almost_equal_eps(a, b))
    return true;*/
  return almost_equal_ulp(a, b);
}

uint32_t count = 64; // -n64 argument in Vortex when running ./ci/blackbox.sh --driver=rtlsim --app=mstress --cores=1 --warps=8 --threads=4

kernel_arg_t kernel_arg = {};
uint64_t kernel_arg_addr;

void cleanup() {
  global_mem.release(kernel_arg.src0_addr);
  global_mem.release(kernel_arg.src1_addr);
  global_mem.release(kernel_arg.dst_addr);
  global_mem.release(kernel_arg_addr);
}

void gen_src_data(std::vector<float>& test_data,
                  std::vector<uint32_t>& addr_table,
                  uint32_t num_points,
                  uint32_t num_addrs) {
  test_data.resize(num_points);
  addr_table.resize(num_addrs);

  for (uint32_t i = 0; i < num_points; ++i) {
    float r = static_cast<float>(std::rand()) / RAND_MAX;
    test_data[i] = r;
  }

  for (uint32_t i = 0; i < num_addrs; ++i) {
    float r = static_cast<float>(std::rand()) / RAND_MAX;
    uint32_t index = static_cast<uint32_t>(r * num_points);
    assert(index < num_points);
    addr_table[i] = index;
  }
}

// originally in the main function
uint32_t num_cores = 1;
uint32_t num_warps = MSTRESS_NUM_WARPS;
uint32_t num_threads = 4;
uint32_t total_threads = num_cores * num_warps * num_threads;

uint32_t num_points, num_addrs, addr_buf_size, src_buf_size, dst_buf_size;
std::vector<uint32_t> h_addr;
std::vector<float> h_src, h_dst;

extern "C" {

void vx_upload_data_init(void) {
  if (count == 0) {
    count = 1;
  }

  std::srand(50);

  num_points = count * total_threads;
  num_addrs = num_points + NUM_LOADS - 1;
  addr_buf_size = num_addrs * sizeof(int32_t);
  src_buf_size  = num_points * sizeof(int32_t);
  dst_buf_size  = num_points * sizeof(int32_t);

  std::cout << "number of points: " << num_points << std::endl;
  std::cout << "addr buffer size: " << addr_buf_size << " bytes" << std::endl;
  std::cout << "src buffer size: " << src_buf_size << " bytes" << std::endl;
  std::cout << "dst buffer size: " << dst_buf_size << " bytes" << std::endl;

  kernel_arg.num_tasks = total_threads;
  kernel_arg.stride = count;

  // allocate device memory
  std::cout << "allocate device memory" << std::endl;
  global_mem.allocate(addr_buf_size, &kernel_arg.src0_addr);
  global_mem.allocate(src_buf_size, &kernel_arg.src1_addr);
  global_mem.allocate(dst_buf_size, &kernel_arg.dst_addr);
  global_mem.allocate(sizeof(kernel_arg_t), &kernel_arg_addr);

  std::cout << "dev_addr=0x" << std::hex << kernel_arg.src0_addr << std::endl;
  std::cout << "dev_src=0x" << std::hex << kernel_arg.src1_addr << std::endl;
  std::cout << "dev_dst=0x" << std::hex << kernel_arg.dst_addr << std::endl;
  std::cout << "dev_kernel_arg=0x" << std::hex << kernel_arg_addr << std::endl;

  // allocate host buffers
  std::cout << "allocate host buffers" << std::endl;
  gen_src_data(h_src, h_addr, num_points, num_addrs);
  h_dst.resize(num_points);
}

uint64_t vx_upload_data(void) {
  static uint64_t offset = 0;
  static char state = 0; // upload source buffer0

  uint64_t addr;
  uint32_t data = 0;
  uint32_t *datas;
  switch (state) {
    case 0:
      if (offset == 0)
        std::cout << "upload source buffer0" << std::endl;
      addr = kernel_arg.src0_addr + offset;
      datas = (uint32_t *)h_addr.data() + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= addr_buf_size) {
        offset = 0;
        ++state;
      }
      break;
    case 1:
      if (offset == 0)
        std::cout << "upload source buffer1" << std::endl;
      addr = kernel_arg.src1_addr + offset;
      datas = (uint32_t *)h_src.data() + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= src_buf_size) {
        offset = 0;
        ++state;
      }
      break;
    case 2:
      if (offset == 0)
        std::cout << "upload kernel argument" << std::endl;
      addr = kernel_arg_addr + offset;
      datas = (uint32_t *)(&kernel_arg) + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= sizeof(kernel_arg_t)) {
        offset = 0;
        ++state;
      }
      break;
    default:
      addr = 1;
  }

  return (addr << 32) | data;
}

uint32_t vx_kernel_arg(void) {
  return (uint32_t)kernel_arg_addr;
}

uint32_t vx_download_data_req(void) {
  static uint64_t offset = 0;
  static char done = 0;

  if (done) return 1;

  uint64_t addr;
  if (offset == 0)
    std::cout << "download destination buffer" << std::endl;
  addr = kernel_arg.dst_addr + offset;
  offset += 4;
  if (offset >= dst_buf_size) {
    done = 1;
  }

  return (uint32_t)addr;
}

void vx_download_data_resp(uint32_t addr, uint32_t data) {
  uint32_t offset = addr - kernel_arg.dst_addr;
  TYPE data_cast;
  static_assert(sizeof(TYPE) == sizeof(uint32_t), "Size is not right");
  std::memcpy(&data_cast, &data, sizeof(TYPE));
  offset = offset >> 2;
  h_dst[offset] = data_cast;
  return;
}

void vx_validate(void) {
  // verify result
  std::cout << "verify result" << std::endl;
  int errors = 0;
  for (uint32_t i = 0; i < num_points; ++i) {
    float ref = 0.0f;
    for (uint32_t j = 0; j < NUM_LOADS; ++j) {
      uint32_t addr = i + j;
      uint32_t index = h_addr[addr];
      float value = h_src[index];
      //printf("*** [%d] addr=%d, index=%d, value=%f\n", i, addr, index, value);
      ref *= value;
    }

    float cur = h_dst[i];
    if (!almost_equal(cur, ref)) {
      std::cout << "error at result #" << std::dec << i
                << ": actual " << cur << ", expected " << ref << std::endl;
      ++errors;
    }
  }

  if (errors != 0) {
    std::cout << "Found " << std::dec << errors << " errors!" << std::endl;
    std::cout << "FAILED!" << std::endl;
    cleanup();
    return;
  }

  std::cout << "PASSED!" << std::endl;
  cleanup();
  return;
}

}
