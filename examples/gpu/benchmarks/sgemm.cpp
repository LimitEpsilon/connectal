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
  uint64_t A_addr;
  uint64_t B_addr;
  uint64_t C_addr;
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

static void matmul_cpu(TYPE* out, const TYPE* A, const TYPE* B, uint32_t width, uint32_t height) {
  for (uint32_t row = 0; row < height; ++row) {
    for (uint32_t col = 0; col < width; ++col) {
      TYPE sum(0);
      for (uint32_t e = 0; e < width; ++e) {
        sum += A[row * width + e] * B[e * width + col];
      }
      out[row * width + col] = sum;
    }
  }
}

uint32_t size = 32; // default in Vortex

kernel_arg_t kernel_arg = {};
uint64_t kernel_arg_addr;

void cleanup() {
  global_mem.release(kernel_arg.A_addr);
  global_mem.release(kernel_arg.B_addr);
  global_mem.release(kernel_arg.C_addr);
  global_mem.release(kernel_arg_addr);
}

// originally in the main function
uint32_t size_sq = size * size;
uint32_t buf_size = size_sq * sizeof(TYPE);
std::vector<TYPE> h_A(size_sq);
std::vector<TYPE> h_B(size_sq);
std::vector<TYPE> h_C(size_sq);

extern "C" {

void vx_upload_data_init(void) {
  std::srand(50);

  std::cout << "data type: " << Comparator<TYPE>::type_str() << std::endl;
  std::cout << "matrix size: " << size << "x" << size << std::endl;

  kernel_arg.grid_dim[0] = size;
  kernel_arg.grid_dim[1] = size;
  kernel_arg.size = size;

  // allocate device memory
  std::cout << "allocate device memory" << std::endl;
  global_mem.allocate(buf_size, &kernel_arg.A_addr);
  global_mem.allocate(buf_size, &kernel_arg.B_addr);
  global_mem.allocate(buf_size, &kernel_arg.C_addr);
  global_mem.allocate(sizeof(kernel_arg_t), &kernel_arg_addr);

  std::cout << "A_addr=0x" << std::hex << kernel_arg.A_addr << std::endl;
  std::cout << "B_addr=0x" << std::hex << kernel_arg.B_addr << std::endl;
  std::cout << "C_addr=0x" << std::hex << kernel_arg.C_addr << std::endl;
  std::cout << "dev_kernel_arg=0x" << std::hex << kernel_arg_addr << std::endl;

  // generate source data
  for (uint32_t i = 0; i < size_sq; ++i) {
    h_A[i] = Comparator<TYPE>::generate();
    h_B[i] = Comparator<TYPE>::generate();
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
        std::cout << "upload matrix A buffer" << std::endl;
      addr = kernel_arg.A_addr + offset;
      datas = (uint32_t *)h_A.data() + (offset >> 2);
      data = *datas;
      offset += 4;
      if (offset >= buf_size) {
        offset = 0;
        ++state;
      }
      break;
    case 1:
      if (offset == 0)
        std::cout << "upload matrix B buffer" << std::endl;
      addr = kernel_arg.B_addr + offset;
      datas = (uint32_t *)h_B.data() + (offset >> 2);
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
  addr = kernel_arg.C_addr + offset;
  offset += 4;
  if (offset >= buf_size) {
    done = 1;
  }

  return (uint32_t)addr;
}

void vx_download_data_resp(uint32_t addr, uint32_t data) {
  uint32_t offset = addr - kernel_arg.C_addr;
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
  {
    std::vector<TYPE> h_ref(size_sq);
    matmul_cpu(h_ref.data(), h_A.data(), h_B.data(), size, size);

    for (uint32_t i = 0; i < h_ref.size(); ++i) {
      if (!Comparator<TYPE>::compare(h_C[i], h_ref[i], i, errors)) {
        ++errors;
      }
    }
  }

  // cleanup
  std::cout << "cleanup" << std::endl;
  cleanup();

  if (errors != 0) {
    std::cout << "Found " << std::dec << errors << " errors!" << std::endl;
    std::cout << "FAILED!" << std::endl;
    return;
  }

  std::cout << "PASSED!" << std::endl;
  return;
}

}
