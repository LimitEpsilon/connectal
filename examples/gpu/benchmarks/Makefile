OS := $(shell uname -s)
CC = g++
CFLAGS = -l elf
ifeq ($(OS),Darwin)
CFLAGS += -I /opt/homebrew/include/libelf -I /opt/homebrew/include -L /opt/homebrew/lib
endif

vecadd: vecadd.cpp
	$(CC) $(CFLAGS) -o vecadd vecadd.cpp main.c

sgemm: sgemm.cpp
	$(CC) $(CFLAGS) -o sgemm sgemm.cpp main.c

mstress: mstress.cpp
	$(CC) $(CFLAGS) -o mstress mstress.cpp main.c

madmax: madmax.cpp
	$(CC) $(CFLAGS) -o madmax madmax.cpp main.c

all: loadelf.h main.c vecadd sgemm mstress madmax

clean:
	rm -rf *.o vecadd sgemm mstress madmax

.PHONY: clean all
.DEFAULT_GOAL := all
