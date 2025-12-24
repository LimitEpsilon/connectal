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

mstress: mstress.cpp
	$(CC) -o mstress mstress.cpp main.c $(CFLAGS)

madmax: madmax.cpp
	$(CC) -o madmax madmax.cpp main.c $(CFLAGS)

all: loadelf.h main.c vecadd sgemm mstress madmax

clean:
	rm -rf *.o vecadd sgemm mstress madmax

.PHONY: clean all
.DEFAULT_GOAL := all
