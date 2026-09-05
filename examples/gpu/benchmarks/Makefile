OS := $(shell uname -s)
CC = g++
CFLAGS = -l elf
ifeq ($(OS),Darwin)
CFLAGS += -I /opt/homebrew/include/libelf -I /opt/homebrew/include -L /opt/homebrew/lib
endif

vecadd: vecadd.cpp
	$(CC) -o vecadd vecadd.cpp main.c $(CFLAGS)

sgemm: sgemm.cpp
	$(CC) -o sgemm sgemm.cpp main.c $(CFLAGS)

MSTRESS_NUM_WARPS ?= 16

mstress: mstress.cpp
	$(CC) -DMSTRESS_NUM_WARPS=$(MSTRESS_NUM_WARPS) -o mstress mstress.cpp main.c $(CFLAGS)

mstress-w8: mstress.cpp
	$(CC) -DMSTRESS_NUM_WARPS=8 -o $@ mstress.cpp main.c $(CFLAGS)

mstress-w16: mstress.cpp
	$(CC) -DMSTRESS_NUM_WARPS=16 -o $@ mstress.cpp main.c $(CFLAGS)

madmax: madmax.cpp
	$(CC) -o madmax madmax.cpp main.c $(CFLAGS)

all: loadelf.h main.c vecadd sgemm mstress mstress-w8 mstress-w16 madmax

clean:
	rm -rf *.o vecadd sgemm mstress mstress-w8 mstress-w16 madmax

.PHONY: clean all
.DEFAULT_GOAL := all
