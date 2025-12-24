#include <iostream>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <vector>
#include "mem_alloc.h"

// defined in common.h for each test case
#define TYPE float

typedef struct {
  uint32_t grid_dim[2];
  uint32_t size;
  uint64_t dst_addr;
} kernel_arg_t;

inline float madmax_compute(uint32_t row, uint32_t col, uint32_t size) {
  // Initialize 16 independent accumulators using thread indices
  float a0 = (row * size + col) * 0.5f;
  float a1 = (col * size + row) * 0.5f;
  float a2 = a0 + a1;
  float a3 = a0 - a1;
  float a4 = a2 * 0.5f;
  float a5 = a3 * 0.5f;
  float a6 = a4 + a5;
  float a7 = a4 - a5;
  float a8 = a6 * 0.5f;
  float a9 = a7 * 0.5f;
  float a10 = a8 + a9;
  float a11 = a8 - a9;
  float a12 = a10 * 0.5f;
  float a13 = a11 * 0.5f;
  float a14 = a12 + a13;
  float a15 = a12 - a13;

  // Perform massive independent FMADD chains (1024 iterations)
  for (int i = 0; i < 256; ++i) {
    a0 = a0 * a1 + a2;
    a1 = a1 * a2 + a3;
    a2 = a2 * a3 + a4;
    a3 = a3 * a4 + a5;
    a4 = a4 * a5 + a6;
    a5 = a5 * a6 + a7;
    a6 = a6 * a7 + a8;
    a7 = a7 * a8 + a9;
    a8 = a8 * a9 + a10;
    a9 = a9 * a10 + a11;
    a10 = a10 * a11 + a12;
    a11 = a11 * a12 + a13;
    a12 = a12 * a13 + a14;
    a13 = a13 * a14 + a15;
    a14 = a14 * a15 + a0;
    a15 = a15 * a0 + a1;
  }

  // Combine results to force dependency and write output
  return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15;
}

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

uint32_t size = 16; // default in Vortex

kernel_arg_t kernel_arg = {};
uint64_t kernel_arg_addr;

// Synthetic computation replica for verification
void compute_reference(float *ref, uint32_t size) {
  for (uint32_t row = 0; row < size; ++row) {
    for (uint32_t col = 0; col < size; ++col) {
      ref[row * size + col] = madmax_compute(row, col, size);
    }
  }
}

void cleanup() {
  global_mem.release(kernel_arg.dst_addr);
  global_mem.release(kernel_arg_addr);
}

// originally in the main function
std::vector<float> h_C(size * size);
uint32_t buf_size = size * size * sizeof(float);

extern "C" {

void vx_upload_data_init(void) {
  std::srand(50);

  std::cout << "number of points: " << size << std::endl;
  std::cout << "buffer size: " << buf_size << " bytes" << std::endl;

  kernel_arg.grid_dim[0] = size;
  kernel_arg.grid_dim[1] = size;
  kernel_arg.size = size;

  // allocate device memory
  std::cout << "allocate device memory" << std::endl;
  global_mem.allocate(buf_size, &kernel_arg.dst_addr);
  global_mem.allocate(sizeof(kernel_arg_t), &kernel_arg_addr);

  std::cout << "dev_dst=0x" << std::hex << kernel_arg.dst_addr << std::endl;
  std::cout << "dev_kernel_arg=0x" << std::hex << kernel_arg_addr << std::endl;
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
  h_C[offset] = data_cast;
  return;
}

void vx_validate(void) {
  // verify result
  std::cout << "verify result" << std::endl;
  int errors = 0;
  std::vector<float> h_ref(size * size);
  compute_reference(h_ref.data(), size);

  for (uint32_t i = 0; i < h_ref.size(); ++i) {
    union fi_t {
      float f;
      int32_t i;
    };
    fi_t actual, expected;
    actual.f = h_C[i];
    expected.f = h_ref[i];

    if (std::abs(actual.i - expected.i) > FLOAT_ULP) {
      if (errors < 3) {
        printf("*** error: [%d] expected=%f, actual=%f\n", i, expected.f, actual.f);
      }
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
