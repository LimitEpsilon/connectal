OS := $(shell uname -s)
CONNECTALDIR?=$(HOME)/connectal
PLATFORMDIR=$(CONNECTALDIR)/platform
MIGDIR=$(PLATFORMDIR)/xilinx/ddr4_v2_2

S2H_INTERFACES = \
	ConnectalProcRequest:ConnectalWrapper.connectProc
H2S_INTERFACES = \
	ConnectalWrapper:ConnectalProcIndication:host

BSVFILES += \
	src/includes/Ifc.bsv
BSVPATH += / \
	src/ \
	src/includes \
	src/includes/hardfloat \
	$(CONNECTALDIR)/bsv \
	$(PLATFORMDIR)/bsvlib \
	$(MIGDIR) \
	$(PLATFORMDIR)/lib/dram_ctrl_sim/ddr4 \
	$(PLATFORMDIR)/lib

CPPFILES += \
	main.cpp

# set main clock period
CONNECTALFLAGS += --mainclockperiod=8

# for DDR
CONNECTALFLAGS += -D IMPORT_HOSTIF -D XILINX_SYS_CLK
CONNECTALFLAGS += --implconstraint $(MIGDIR)/ddr4_vcu108.xdc

# assume BOARD == vcu108
DDR4_V = $(CONNECTALDIR)/out/$(BOARD)/ddr4_0/ddr4_0_stub.v
CONNECTALFLAGS += --verilog $(MIGDIR)/ddr4_wrapper.v --xci $(CONNECTALDIR)/out/$(BOARD)/ddr4_0/ddr4_0.xci

SYNCFIFO_784_32 = $(CONNECTALDIR)/out/$(BOARD)/sync_bram_fifo_w784_d32/sync_bram_fifo_w784_d32.xci
SYNCFIFO_640_32 = $(CONNECTALDIR)/out/$(BOARD)/sync_bram_fifo_w640_d32/sync_bram_fifo_w640_d32.xci

CONNECTALFLAGS += --xci $(SYNCFIFO_784_32) --xci $(SYNCFIFO_640_32)

# compiler flags
ifeq ($(OS),Darwin)
CONNECTALFLAGS += --cxxflags="-Wall -I/opt/homebrew/include/libelf -I/opt/homebrew/include -L/opt/homebrew/lib"
endif
CONNECTALFLAGS += --clib="elf"
CONNECTALFLAGS += --bscflags " -steps-max-intervals 50 +RTS -K256M -RTS"
CONNECTALFLAGS += --bscflags " -show-schedule"

# gpu specific defines
CONNECTALFLAGS += -D THREAD_NUM=4 -D WARP_NUM=16

ifeq ($(BOARD),vcu108)
prebuild:: $(DDR4_V) $(SYNCFIFO_784_32) $(SYNCFIFO_640_32)

$(DDR4_V): $(PLATFORMDIR)/core-scripts/synth-ddr4.tcl
	(cd $(BOARD); vivado -mode batch -source $(PLATFORMDIR)/core-scripts/synth-ddr4.tcl)

$(SYNCFIFO_784_32): $(PLATFORMDIR)/core-scripts/synth_sync_bram_fifo.tcl
	(cd $(PROJECTDIR); vivado -mode batch -source $^ -tclargs 784 32)

$(SYNCFIFO_640_32): $(PLATFORMDIR)/core-scripts/synth_sync_bram_fifo.tcl
	(cd $(PROJECTDIR); vivado -mode batch -source $^ -tclargs 640 32)
endif

PIN_TYPE = Top_Pins
PIN_TYPE_INCLUDE = ConnectalWrapper
AUTOTOP = --interface pins:ConnectalWrapper.pins

include $(CONNECTALDIR)/Makefile.connectal

