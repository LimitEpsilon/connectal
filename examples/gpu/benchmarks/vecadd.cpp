#include <iostream>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <vector>
#include "mem_alloc.h"

// defined in common.h for each test case
#define TYPE float

typedef struct {
  uint32_t num_points;
  uint64_t src0_addr;
  uint64_t src1_addr;
  uint64_t dst_addr;
} kernel_arg_t;

MemoryAllocator global_mem =
  MemoryAllocator(ALLOC_BASE_ADDR, GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR, MEM_PAGE_SIZE, CACHE_BLOCK_SIZE);

// start of main.cpp
#define FLOAT_ULP 6

template <typename Type>
class Comparator {};

template <>
class Comparator<int> {
public:
  static const char* type_str() {
    return "integer";
  }
  static int generate() {
    return rand();
  }
  static bool compare(int a, int b, int index, int errors) {
    if (a != b) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%d, actual=%d\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<float> {
private:
  union Float_t { float f; int i; };
public:
  static const char* type_str() {
    return "float";
  }
  static float generate() {
    return static_cast<float>(rand()) / RAND_MAX;
  }
  static bool compare(float a, float b, int index, int errors) {
    union fi_t { float f; int32_t i; };
    fi_t fa, fb;
    fa.f = a;
    fb.f = b;
    auto d = std::abs(fa.i - fb.i);
    if (d > FLOAT_ULP) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%f, actual=%f\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

uint32_t size = 64; // default in Vortex

kernel_arg_t kernel_arg = {};
uint64_t kernel_arg_addr;

void cleanup() {
  global_mem.release(kernel_arg.src0_addr);
  global_mem.release(kernel_arg.src1_addr);
  global_mem.release(kernel_arg.dst_addr);
  global_mem.release(kernel_arg_addr);
}

// originally in the main function
uint32_t num_points = size;
std::vector<TYPE> h_src0(num_points);
std::vector<TYPE> h_src1(num_points);
std::vector<TYPE> h_dst(num_points);
uint32_t buf_size = num_points * sizeof(TYPE);

extern "C" {

void vx_upload_data_init(void) {
  std::srand(50);

  std::cout << "number of points: " << num_points << std::endl;
  std::cout << "data type: " << Comparator<TYPE>::type_str() << std::endl;
  std::cout << "buffer size: " << buf_size << " bytes" << std::endl;

  kernel_arg.num_points = num_points;

  // allocate device memory
  std::cout << "allocate device memory" << std::endl;
  global_mem.allocate(buf_size, &kernel_arg.src0_addr);
  global_mem.allocate(buf_size, &kernel_arg.src1_addr);
  global_mem.allocate(buf_size, &kernel_arg.dst_addr);
  global_mem.allocate(sizeof(kernel_arg_t), &kernel_arg_addr);

  std::cout << "dev_src0=0x" << std::hex << kernel_arg.src0_addr << std::endl;
  std::cout << "dev_src1=0x" << std::hex << kernel_arg.src1_addr << std::endl;
  std::cout << "dev_dst=0x" << std::hex << kernel_arg.dst_addr << std::endl;
  std::cout << "dev_kernel_arg=0x" << std::hex << kernel_arg_addr << std::endl;

  // allocate host buffers
  std::cout << "allocate host buffers" << std::endl;

  for (uint32_t i = 0; i < num_points; ++i) {
    h_src0[i] = Comparator<TYPE>::generate();
    h_src1[i] = Comparator<TYPE>::generate();
  }
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
      datas = (uint32_t *)h_src0.data() + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= buf_size) {
        offset = 0;
        ++state;
      }
      break;
    case 1:
      if (offset == 0)
        std::cout << "upload source buffer1" << std::endl;
      addr = kernel_arg.src1_addr + offset;
      datas = (uint32_t *)h_src1.data() + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= buf_size) {
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
  if (offset >= buf_size) {
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
    auto ref = h_src0[i] + h_src1[i];
    auto cur = h_dst[i];
    if (!Comparator<TYPE>::compare(cur, ref, i, errors)) {
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
