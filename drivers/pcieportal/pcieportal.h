/* Copyright (c) 2014 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
#ifndef __BLUENOC_H__
#define __BLUENOC_H__

/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_ASM_GENERIC_IOCTL_H
#define _UAPI_ASM_GENERIC_IOCTL_H

/* ioctl command encoding: 32 bits total, command in lower 16 bits,
 * size of the parameter structure in the lower 14 bits of the
 * upper 16 bits.
 * Encoding the size of the parameter structure in the ioctl request
 * is useful for catching programs compiled with old versions
 * and to avoid overwriting user space outside the user buffer area.
 * The highest 2 bits are reserved for indicating the ``access mode''.
 * NOTE: This limits the max parameter size to 16kB -1 !
 */

/*
 * The following is for compatibility across the various Linux
 * platforms.  The generic ioctl numbering scheme doesn't really enforce
 * a type field.  De facto, however, the top 8 bits of the lower 16
 * bits are indeed used as a type field, so we might just as well make
 * this explicit here.  Please be sure to use the decoding macros
 * below from now on.
 */
#define _IOC_NRBITS 8
#define _IOC_TYPEBITS 8

/*
 * Let any architecture override either of the following before
 * including this file.
 */

#ifndef _IOC_SIZEBITS
#define _IOC_SIZEBITS 14
#endif

#ifndef _IOC_DIRBITS
#define _IOC_DIRBITS 2
#endif

#define _IOC_NRMASK ((1 << _IOC_NRBITS) - 1)
#define _IOC_TYPEMASK ((1 << _IOC_TYPEBITS) - 1)
#define _IOC_SIZEMASK ((1 << _IOC_SIZEBITS) - 1)
#define _IOC_DIRMASK ((1 << _IOC_DIRBITS) - 1)

#define _IOC_NRSHIFT 0
#define _IOC_TYPESHIFT (_IOC_NRSHIFT + _IOC_NRBITS)
#define _IOC_SIZESHIFT (_IOC_TYPESHIFT + _IOC_TYPEBITS)
#define _IOC_DIRSHIFT (_IOC_SIZESHIFT + _IOC_SIZEBITS)

/*
 * Direction bits, which any architecture can choose to override
 * before including this file.
 *
 * NOTE: _IOC_WRITE means userland is writing and kernel is
 * reading. _IOC_READ means userland is reading and kernel is writing.
 */

#ifndef _IOC_NONE
#define _IOC_NONE 0U
#endif

#ifndef _IOC_WRITE
#define _IOC_WRITE 1U
#endif

#ifndef _IOC_READ
#define _IOC_READ 2U
#endif

#define _IOC(dir, type, nr, size)                                              \
  (((dir) << _IOC_DIRSHIFT) | ((type) << _IOC_TYPESHIFT) |                     \
   ((nr) << _IOC_NRSHIFT) | ((size) << _IOC_SIZESHIFT))

#ifndef __KERNEL__
#define _IOC_TYPECHECK(t) (sizeof(t))
#endif

/*
 * Used to create numbers.
 *
 * NOTE: _IOW means userland is writing and kernel is reading. _IOR
 * means userland is reading and kernel is writing.
 */
#define _IO(type, nr) _IOC(_IOC_NONE, (type), (nr), 0)
#define _IOR(type, nr, argtype)                                                \
  _IOC(_IOC_READ, (type), (nr), (_IOC_TYPECHECK(argtype)))
#define _IOW(type, nr, argtype)                                                \
  _IOC(_IOC_WRITE, (type), (nr), (_IOC_TYPECHECK(argtype)))
#define _IOWR(type, nr, argtype)                                               \
  _IOC(_IOC_READ | _IOC_WRITE, (type), (nr), (_IOC_TYPECHECK(argtype)))
#define _IOR_BAD(type, nr, argtype)                                            \
  _IOC(_IOC_READ, (type), (nr), sizeof(argtype))
#define _IOW_BAD(type, nr, argtype)                                            \
  _IOC(_IOC_WRITE, (type), (nr), sizeof(argtype))
#define _IOWR_BAD(type, nr, argtype)                                           \
  _IOC(_IOC_READ | _IOC_WRITE, (type), (nr), sizeof(argtype))

/* used to decode ioctl numbers.. */
#define _IOC_DIR(nr) (((nr) >> _IOC_DIRSHIFT) & _IOC_DIRMASK)
#define _IOC_TYPE(nr) (((nr) >> _IOC_TYPESHIFT) & _IOC_TYPEMASK)
#define _IOC_NR(nr) (((nr) >> _IOC_NRSHIFT) & _IOC_NRMASK)
#define _IOC_SIZE(nr) (((nr) >> _IOC_SIZESHIFT) & _IOC_SIZEMASK)

/* ...and for the drivers/sound files... */

#define IOC_IN (_IOC_WRITE << _IOC_DIRSHIFT)
#define IOC_OUT (_IOC_READ << _IOC_DIRSHIFT)
#define IOC_INOUT ((_IOC_WRITE | _IOC_READ) << _IOC_DIRSHIFT)
#define IOCSIZE_MASK (_IOC_SIZEMASK << _IOC_SIZESHIFT)
#define IOCSIZE_SHIFT (_IOC_SIZESHIFT)

#endif /* _UAPI_ASM_GENERIC_IOCTL_H */

/*
 * IOCTLs
 */

/* magic number for IOCTLs */
#define BNOC_IOC_MAGIC 0xB5

/* Number of boards to support */
#define NUM_BOARDS 4
#define MAX_NUM_PORTALS 32

/* Structures used with IOCTLs */

typedef struct {
  unsigned long base;
  unsigned int trace;
  unsigned int traceLength;
  unsigned int intval[MAX_NUM_PORTALS];
  unsigned int name[MAX_NUM_PORTALS];
} tTraceInfo;

typedef struct {
  int fd;
  int id;
} tSendFd;

typedef struct {
  int index;         /* in param */
  char md5[33];      /* out param -- asciz */
  char filename[33]; /* out param -- asciz */
} PortalSignaturePcie;

typedef unsigned int tTlpData[6];

typedef struct ChangeEntry {
  unsigned int timestamp;
  unsigned char src;
  unsigned int value : 24;
} tChangeEntry;
/* IOCTL code definitions */

#define BNOC_GET_TLP _IOR(BNOC_IOC_MAGIC, 7, tTlpData *)
#define BNOC_TRACE _IOWR(BNOC_IOC_MAGIC, 8, tTraceInfo *)
#define BNOC_ENABLE_TRACE _IOR(BNOC_IOC_MAGIC, 8, int *)
#define PCIE_SEND_FD _IOR(BNOC_IOC_MAGIC, 12, tSendFd *)
#define PCIE_DEREFERENCE _IOR(BNOC_IOC_MAGIC, 13, int)
#define PCIE_SIGNATURE _IOR(BNOC_IOC_MAGIC, 14, PortalSignaturePcie)
#define PCIE_CHANGE_ENTRY _IOR(BNOC_IOC_MAGIC, 15, tChangeEntry *)

#ifdef __KERNEL__
/*
 * Per-device data
 */
typedef struct {
  unsigned int device_number;
  unsigned int device_tile;
  unsigned int portal_number;
  unsigned int device_name;
  struct tBoard *board;
  void *virt;
  volatile uint32_t *regs; // Pointer to access portal from kernel
  unsigned long offset;    // Offset from base of BAR2
  struct extra_info *extra;
  struct list_head pmlist;
} tPortal;

typedef struct {
  unsigned int device_tile;
  struct tBoard *board;
} tTile;

struct pmentry {
  struct file *fmem;
  int id;
  struct list_head pmlist;
};

typedef struct tBoard {
  void __iomem *bar0io, *bar1io, *bar2io, *bar4io; /* bars */
  struct pci_dev *pci_dev;                         /* pci device pointer */
  tPortal portal[MAX_NUM_PORTALS];
  unsigned int irq_num;
  unsigned int open_count;
  tTile tile[MAX_NUM_PORTALS];
  struct extra_info *extra;
  struct extra_info *pcis; // DMA PCIS on AWSF1
  struct {
    unsigned int board_number;
    unsigned int portal_number;
    unsigned int num_portals;
    unsigned int aws_shell;
  } info; /* board identification fields */
} tBoard;

extern tBoard *get_pcie_portal_descriptor(void);
#endif

#endif /* __BLUENOC_H__ */
