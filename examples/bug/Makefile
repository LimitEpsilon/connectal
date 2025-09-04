OS := $(shell uname -s)
CONNECTALDIR?=$(HOME)/connectal

S2H_INTERFACES = \
	ConnectalProcRequest:ConnectalWrapper.connectProc
H2S_INTERFACES = \
	ConnectalWrapper:ConnectalProcIndication

BSVFILES += \
	src/Ifc.bsv
BSVPATH += / \
	src/ \
	$(CONNECTALDIR)/bsv

CPPFILES += \
	main.cpp

# compiler flags
CONNECTALFLAGS += --bscflags " -steps-max-intervals 50 +RTS -K256M -RTS"
CONNECTALFLAGS += --bscflags " -show-schedule"

PIN_TYPE = Top_Pins
PIN_TYPE_INCLUDE = ConnectalWrapper
AUTOTOP = --interface pins:ConnectalWrapper.pins

include $(CONNECTALDIR)/Makefile.connectal

