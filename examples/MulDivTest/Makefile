
# Copyright (c) 2017 Massachusetts Institute of Technology
# 
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use, copy,
# modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

CONNECTALDIR = $(HOME)/connectal

PROJ_DIR = $(abspath .)
FPGA_LIB_DIR = $(PROJ_DIR)/../../platform/lib
XILINX_IP_DIR = $(PROJ_DIR)/../../platform/xilinx
CORE_SCRIPT_DIR = $(PROJ_DIR)/../../platform/core-scripts

BUILD_DIR = $(PROJ_DIR)/build
PROJECTDIR = $(BUILD_DIR)/$(BOARD)

S2H_INTERFACES = MulDivTestRequest:MulDivTestWrapper.request
H2S_INTERFACES = MulDivTestWrapper:MulDivTestIndication

BSVFILES = $(PROJ_DIR)/bsv/MulDivTestIF.bsv

CPPFILES = $(PROJ_DIR)/cpp/main.cpp

CONNECTALFLAGS += --nocache -v \
				  --bsvpath $(PROJ_DIR)/bsv \
				  --bsvpath $(FPGA_LIB_DIR) \
				  --cflags " -std=c++0x " \
				  --bscflags " -check-assert "

CONNECTALFLAGS += --mainclockperiod=8

# test specific params
CONNECTALFLAGS += -D USER_TAG_SIZE=4 \
				  -D MAX_TEST_NUM=1024 \
				  -D LOG_DELAY_CYCLES=7

ifeq ($(BOARD),$(filter $(BOARD),vc707 vcu108))
# synthesize for VC707 or vcu108

# VC707 needs some more clocking constraints
ifeq ($(BOARD),vc707)
CONNECTALFLAGS += -C $(XILINX_IP_DIR)/vc707/constraints/clocks.xdc
endif

else
# simulation

CONNECTALFLAGS += -D BSIM

endif


include $(CONNECTALDIR)/Makefile.connectal

clean.%:
	rm -rf $(BUILD_DIR)/$*

