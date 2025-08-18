CONNECTALDIR ?= connectal
S2H_INTERFACES = \
	ConnectalProcRequest:ConnectalWrapper.connectProc
H2S_INTERFACES = \
	ConnectalWrapper:ConnectalProcIndication
BSVFILES += \
	src/includes/Ifc.bsv
BSVPATH += / \
	src/ \
	src/includes \
	$(CONNECTALDIR)/bsv
CPPFILES += \
	main.cpp \
	loadelf.cpp

OS := $(shell uname -s)

ifeq ($(OS),Darwin)
CONNECTALFLAGS += --cxxflags="-I/opt/homebrew/include/libelf -I/opt/homebrew/include -L/opt/homebrew/lib"
endif
CONNECTALFLAGS += --clib="elf"

TNUM = 4
WNUM = 8

#CONNECTALFLAGS += --mainclockperiod=20
#CONNECTALFLAGS += --verilog=ddr3_v2_0/
SOFTWARE_SOCKET_NAME=/tmp/connectal$(USER)
CONNECTALFLAGS += -D THREAD_NUM=$(TNUM) -D WARP_NUM=$(WNUM)
CONNECTALFLAGS += --bscflags " -steps-max-intervals 50 +RTS -K256M -RTS"
CONNECTALFLAGS += --bscflags " -show-schedule"

include $(CONNECTALDIR)/Makefile.connectal

clean:
	rm -rf bluesim

