// Copyright (c) 2013-2018 Bluespec, Inc. All Rights Reserved

// This program reads an ELF file and outputs a Verilog hex memory
// image file (suitable for reading using $readmemh).

// ================================================================
// Standard C includes

#pragma once

#include <fcntl.h>
#include <gelf.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <sys/syslimits.h>
#else
#include <limits.h>
#endif

// ================================================================
// Memory buffer into which we load the ELF file before
// writing it back out to the output file.

// 1 Gigabyte size
#define MAX_MEM_SIZE ((uint64_t)0x90000000)

static uint8_t *mem_buf = NULL;

// Features of the ELF binary
static int bitwidth;
static uint64_t min_addr;
static uint64_t max_addr;

static uint64_t pc_start;    // Addr of label  '_start'
static uint64_t pc_exit;     // Addr of label  'exit'
static uint64_t tohost_addr; // Addr of label  'tohost'

// ================================================================
// Load an ELF file.

static void c_mem_load_elf(const char *elf_filename, const char *start_symbol,
                           const char *exit_symbol, const char *tohost_symbol) {
  int fd;
  // int n_initialized = 0;
  Elf *e;

  // Default start, exit and tohost symbols
  if (start_symbol == NULL)
    start_symbol = "_start";
  if (exit_symbol == NULL)
    exit_symbol = "exit";
  if (tohost_symbol == NULL)
    tohost_symbol = "tohost";

  // Verify the elf library version
  if (elf_version(EV_CURRENT) == EV_NONE) {
    fprintf(
        stderr,
        "ERROR: c_mem_load_elf: Failed to initialize the libelfg library!\n");
    exit(1);
  }

  // Open the file for reading
  fd = open(elf_filename, O_RDONLY, 0);
  if (fd < 0) {
    fprintf(stderr,
            "ERROR: c_mem_load_elf: could not open elf input file: %s\n",
            elf_filename);
    exit(1);
  }

  // Initialize the Elf pointer with the open file
  e = elf_begin(fd, ELF_C_READ, NULL);
  if (e == NULL) {
    fprintf(stderr,
            "ERROR: c_mem_load_elf: elf_begin() initialization failed!\n");
    exit(1);
  }

  // Verify that the file is an ELF file
  if (elf_kind(e) != ELF_K_ELF) {
    elf_end(e);
    fprintf(stderr,
            "ERROR: c_mem_load_elf: specified file '%s' is not an ELF file!\n",
            elf_filename);
    exit(1);
  }

  // Get the ELF header
  GElf_Ehdr ehdr;
  if (gelf_getehdr(e, &ehdr) == NULL) {
    elf_end(e);
    fprintf(stderr, "ERROR: c_mem_load_elf: get_getehdr() failed: %s\n",
            elf_errmsg(-1));
    exit(1);
  }

  // Is this a 32b or 64 ELF?
  if (gelf_getclass(e) == ELFCLASS32) {
    fprintf(stderr, "c_mem_load_elf: %s is a 32-bit ELF file\n", elf_filename);
    bitwidth = 32;
  } else if (gelf_getclass(e) == ELFCLASS64) {
    fprintf(stderr, "c_mem_load_elf: %s is a 64-bit ELF file\n", elf_filename);
    bitwidth = 64;
  } else {
    fprintf(stderr, "ERROR: c_mem_load_elf: ELF file '%s' is not 32b or 64b\n",
            elf_filename);
    elf_end(e);
    exit(1);
  }

  // Verify we are dealing with a RISC-V ELF
  if (ehdr.e_machine != 243) { // EM_RISCV is not defined, but this returns 243
                               // when used with a valid elf file.
    elf_end(e);
    fprintf(stderr, "ERROR: c_mem_load_elf: %s is not a RISC-V ELF file\n",
            elf_filename);
    exit(1);
  }

  // Verify we are dealing with a little endian ELF
  if (ehdr.e_ident[EI_DATA] != ELFDATA2LSB) {
    elf_end(e);
    fprintf(stderr,
            "ERROR: c_mem_load_elf: %s is a big-endian 64-bit RISC-V "
            "executable which is not supported\n",
            elf_filename);
    exit(1);
  }

  // Grab the string section index
  size_t shstrndx;
  shstrndx = ehdr.e_shstrndx;

  // Iterate through each of the sections looking for code that should be loaded
  Elf_Scn *scn = 0;
  GElf_Shdr shdr;

  min_addr = 0xFFFFFFFFFFFFFFFFllu;
  max_addr = 0x0000000000000000llu;
  pc_start = 0xFFFFFFFFFFFFFFFFllu;
  pc_exit = 0xFFFFFFFFFFFFFFFFllu;
  tohost_addr = 0xFFFFFFFFFFFFFFFFllu;

  while ((scn = elf_nextscn(e, scn)) != NULL) {
    // get the header information for this section
    gelf_getshdr(scn, &shdr);

    char *sec_name = elf_strptr(e, shstrndx, shdr.sh_name);
    fprintf(stderr, "Section %-16s: ", sec_name);

    Elf_Data *data = 0;
    // If we find a code/data section, load it into the model
    if (((shdr.sh_type == SHT_PROGBITS) || (shdr.sh_type == SHT_NOBITS) ||
         (shdr.sh_type == SHT_INIT_ARRAY) ||
         (shdr.sh_type == SHT_FINI_ARRAY)) &&
        ((shdr.sh_flags & SHF_WRITE) || (shdr.sh_flags & SHF_ALLOC) ||
         (shdr.sh_flags & SHF_EXECINSTR))) {
      data = elf_getdata(scn, data);

      // n_initialized += data->d_size;
      if (shdr.sh_addr < min_addr)
        min_addr = shdr.sh_addr;
      if (max_addr < (shdr.sh_addr + data->d_size - 1)) // shdr.sh_size + 4))
        max_addr = shdr.sh_addr + data->d_size - 1;     // shdr.sh_size + 4;

      if (max_addr >= MAX_MEM_SIZE) {
        fprintf(stderr,
                "INTERNAL ERROR: max_addr (0x%0" PRIx64
                ") > buffer size (0x%0" PRIx64 ")\n",
                max_addr, MAX_MEM_SIZE);
        fprintf(stderr, "    Please increase the #define in this program, "
                        "recompile, and run again\n");
        fprintf(stderr, "    Abandoning this run\n");
        exit(1);
      }

      if (shdr.sh_type != SHT_NOBITS) {
        memcpy(&(mem_buf[shdr.sh_addr]), data->d_buf, data->d_size);
      }
      fprintf(stderr,
              "addr %16" PRIx64 " to addr %16" PRIx64
              "; size 0x%8lx (= %0ld) bytes\n",
              shdr.sh_addr, shdr.sh_addr + data->d_size, data->d_size,
              data->d_size);

    }

    // If we find the symbol table, search for symbols of interest
    else if (shdr.sh_type == SHT_SYMTAB) {
      fprintf(stderr,
              "Searching for addresses of '%s', '%s' and '%s' symbols\n",
              start_symbol, exit_symbol, tohost_symbol);

      // Get the section data
      data = elf_getdata(scn, data);

      // Get the number of symbols in this section
      int symbols = shdr.sh_size / shdr.sh_entsize;

      // search for the uart_default symbols we need to potentially modify.
      GElf_Sym sym;
      int i;
      for (i = 0; i < symbols; ++i) {
        // get the symbol data
        gelf_getsym(data, i, &sym);

        // get the name of the symbol
        char *name = elf_strptr(e, shdr.sh_link, sym.st_name);

        // Look for, and remember PC of the start symbol
        if (strcmp(name, start_symbol) == 0) {
          pc_start = sym.st_value;
        }
        // Look for, and remember PC of the exit symbol
        else if (strcmp(name, exit_symbol) == 0) {
          pc_exit = sym.st_value;
        }
        // Look for, and remember addr of 'tohost' symbol
        else if (strcmp(name, tohost_symbol) == 0) {
          tohost_addr = sym.st_value;
        }
      }
    } else {
      fprintf(stderr, "Ignored\n");
    }
  }

  elf_end(e);

  fprintf(stderr, "Min addr:            %16" PRIx64 " (hex)\n", min_addr);
  fprintf(stderr, "Max addr:            %16" PRIx64 " (hex)\n", max_addr);
}

// ================================================================
// Min and max byte addrs for various mem sizes

#define BASE_ADDR_B 0x80000000lu

// For 16 MB memory at 0x_8000_0000
#define MIN_MEM_ADDR_16MB BASE_ADDR_B
#define MAX_MEM_ADDR_16MB (BASE_ADDR_B + 0x1000000lu)

// For 256 MB memory at 0x_8000_0000
#define MIN_MEM_ADDR_256MB BASE_ADDR_B
#define MAX_MEM_ADDR_256MB (BASE_ADDR_B + 0x10000000lu)

// ================================================================

extern "C" {

// Write out from word containing addr1 to word containing addr2
uint64_t vx_upload_kernel() {
  static uint64_t addr1 = BASE_ADDR_B;
  static const uint64_t bits_per_raw_mem_word = 32;
  static uint64_t offset = -4;

  uint64_t addr2 = max_addr;
  uint64_t bytes_per_raw_mem_word = bits_per_raw_mem_word / 8;
  uint64_t raw_mem_word_align_mask =
      (~((uint64_t)(bytes_per_raw_mem_word - 1)));

  // Align the start and end addrs to raw mem words
  uint64_t a1 = (addr1 & raw_mem_word_align_mask);
  uint64_t a2 =
      ((addr2 + bytes_per_raw_mem_word - 1) & raw_mem_word_align_mask);

  offset += 4;
  uint64_t addr = a1 + offset;
  uint64_t data = 0;
  if (a2 <= addr) {
    if (mem_buf != NULL)
      free(mem_buf);
    mem_buf = NULL;
    return (uint64_t)1 << 32;
  } else {
    for (int i = (bytes_per_raw_mem_word - 1); i >= 0; i--)
      data = data << 8 | mem_buf[addr + i];
    return ((offset << 32) | data);
  }
}

// ================================================================

uint32_t vx_upload_kernel_init(const char *input) {
  char pathbuf[PATH_MAX];

  const char *mem = realpath(input, pathbuf);

  mem_buf = (uint8_t *)malloc(sizeof(uint8_t) * MAX_MEM_SIZE);
  if (mem_buf == NULL) {
    fprintf(stderr, "Could not allocate mem_buf of size %lu bytes\n",
            MAX_MEM_SIZE);
    return 1;
  }

  // Zero out the memory buffer before loading the ELF file
  bzero(mem_buf, MAX_MEM_SIZE);

  c_mem_load_elf(mem, "_start", "exit", "tohost");

  if ((min_addr < BASE_ADDR_B) || (MAX_MEM_ADDR_256MB <= max_addr)) {
    fprintf(stderr,
            "Could not allocate mem_buf of min_addr %lu, max_addr %lu\n",
            min_addr, max_addr);
    return 1;
  }

  fprintf(stderr, "Loading elf to processor\n");
  return 0;
}

}
