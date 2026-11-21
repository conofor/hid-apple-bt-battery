# Out-of-tree build of the patched hid-apple module
# (battery reporting over Bluetooth for Magic Keyboard, based on
#  Alec Hall's patch series "HID: apple: report Magic Keyboard battery
#  over Bluetooth", adapted to kernel 6.12 and the NUMPAD 2015 variant).
obj-m := hid-apple.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
