# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree build of the in-kernel rtw89 driver (tested on kernel 7.0.13)
# with RTW89 debug + debugfs support enabled.
# Apply patches 0001/0002 to the extracted in-tree driver directory first,
# then place this Makefile in that directory and run `make`.
#
# Only the modules needed for the RTL8852CE are built; see Makefile.in-tree
# (the original) for other chip variants.

obj-m += rtw89_core.o rtw89_pci.o rtw89_8852c.o rtw89_8852ce.o

rtw89_core-y := core.o \
		mac80211.o \
		mac.o \
		mac_be.o \
		phy.o \
		phy_be.o \
		fw.o \
		cam.o \
		efuse.o \
		efuse_be.o \
		regd.o \
		sar.o \
		coex.o \
		ps.o \
		chan.o \
		ser.o \
		acpi.o \
		util.o \
		wow.o \
		debug.o

rtw89_pci-y := pci.o pci_be.o

rtw89_8852c-y := rtw8852c.o \
		 rtw8852c_table.o \
		 rtw8852c_rfk.o \
		 rtw8852c_rfk_table.o

rtw89_8852ce-y := rtw8852ce.o

ccflags-y += -DCONFIG_RTW89_DEBUG -DCONFIG_RTW89_DEBUGFS

.PHONY: all clean
all:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) clean
