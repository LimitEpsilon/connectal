CONNECTALDIR?=../..
S2H_INTERFACES = Ddr3TestRequest:DdrAws.request
H2S_INTERFACES = DdrAws:Ddr3TestIndication

BSVFILES= \
    DdrAws.bsv\
    Axi4Ddr.bsv

CPPFILES= testddr3.cpp


PIN_TYPE = Axi4DdrMaster
PIN_TYPE_INCLUDE = Axi4Ddr
AUTOTOP = --interface pins:DdrAws.ddr3

CONNECTALFLAGS += -D AWSF1_DDR_A

include $(CONNECTALDIR)/Makefile.connectal
