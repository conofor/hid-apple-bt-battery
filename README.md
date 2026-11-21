# hid-apple: Magic Keyboard battery over Bluetooth

Out-of-tree build of `drivers/hid/hid-apple.c` with working battery
reporting for the Apple Magic Keyboard over Bluetooth, including the
"with Numeric Keypad" variant.  Tested on Debian 13, kernel 6.12, with
a Magic Keyboard with Numeric Keypad (A1644, `004C:026C` over
Bluetooth).

## Why this exists

The keyboard exposes its battery level, but it never showed up on the
desktop: no sysfs percentage, no battery in GNOME/KDE.  Fixing that
properly turned out to be three separate problems stacked on top of
each other.

### 1. Battery reporting was USB-only

The `APPLE_RDESC_BATTERY` quirk (redefined report descriptor exposing a
battery usage) is only set for the USB entries in the device table; the
Bluetooth entry for the Numeric Keypad variant never reports a battery
at all.

This is what Alec Hall's series
[`HID: apple: report Magic Keyboard battery over Bluetooth` (v1)][lore]
fixes: enable the quirk on the Bluetooth entry and move the periodic
fetch from a timer callback into a workqueue, because over the uhid
transport `hid_hw_request()` sleeps while waiting for bluetoothd, and
sleeping in atomic (timer) context deadlocks the kernel.

This repository takes that series as its base and fixes two further
problems the base series still has in practice.

### 2. Any sysfs reader can deadlock the whole Bluetooth stack

With the quirk enabled over Bluetooth, the HID core also starts asking
for the battery itself: as long as no level has been *reported*, every
read of `/sys/class/power_supply/hid-XX:...-battery/capacity` triggers a
synchronous `GET_REPORT` (`hidinput_query_battery_capacity`).  Over
uhid that request is answered by bluetoothd — so any reader running
inside bluetoothd (or inside anything bluetoothd waits on) deadlocks
the daemon for the whole kernel request timeout, freezing every
Bluetooth connection, every few seconds, for minutes at a time.

The fix: set `hdev->battery_avoid_query = true` in `probe()` so the HID
core never issues those synchronous queries for this device, and read
the level from the driver's own workqueue instead (`hid_hw_raw_request`
from process context is fine).  The workqueue keeps
`hdev->battery_capacity` fresh and calls `power_supply_changed()`, so
sysfs readers always see the last known value instantly, without any
HID round trip.

### 3. The firmware's battery report has a status byte

The device answers a `GET_REPORT` for the battery with
`[report id][status][level]`, while the HID core's query path (and a
naive reader) assume `[report id][level]` — so the status byte
(always `0x00` here) is taken as the level and the battery stays
"unknown" for a minute or two after every (re)connect, triggering a
storm of re-queries.  The fetch now parses `buf[2]`.

### Reconnect handling

Two extras make reconnects behave:

* An 8-entry per-address cache of the last known level.  On `probe()`
  the power_supply class device is seeded with it, so the battery
  appears immediately after a reconnect instead of staying unknown
  until the first firmware read completes.
* The firmware answers with a transient "unknown" level right after a
  (re)connect.  A zero never clobbers the seeded value, and the fetch
  retries with shortening intervals (2 s, 8 s, 20 s, 30 s) before
  settling into the normal 60 s period.

## Result

`/sys/class/power_supply/hid-90:9c:...-battery/capacity` is always
populated, the battery shows up in `upower -d`, KDE/GNOME battery
panels and `bluetoothctl info` (via the companion [bluez
kernel-battery plugin][companion]), and toggling Bluetooth or
re-connecting the keyboard no longer freezes anything.

## Build and install

Requires `linux-headers-$(uname -r)`:

```
make
sudo rmmod hid_apple
sudo insmod hid-apple.ko
```

To keep it installed across reboots, copy it over the shipped module
(or use a distro-specific initramfs/module recipe):

```
sudo cp hid-apple.ko /lib/modules/$(uname -r)/kernel/drivers/hid/hid-apple.ko
sudo depmod -a
```

Rebuild after every kernel upgrade.

## Troubleshooting: Intel Bluetooth controllers going to sleep

If *all* Bluetooth devices freeze every few seconds when the air is
quiet, check whether the Intel Bluetooth controller (e.g. Jefferson
Peak `8087:0aaa`) is being USB-autosuspended — with autosuspend enabled
the controller drops every link at once whenever the bus idles, and the
reconnect storm looks exactly like the battery deadlock described
above.  Keep the controller awake:

```
# /etc/udev/rules.d/89-bt-autosuspend.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0aaa", ATTR{power/control}="on"
```

Verify with `cat /sys/bus/usb/devices/1-X/power/runtime_status` and
`runtime_suspended_time` — the latter must not grow while devices are
connected.

## Credits

* Base series: Alec Hall, **"HID: apple: report Magic Keyboard battery
  over Bluetooth" (v1)** — [lore.kernel.org][lore] and
  [hall-alec/magic-hid-bt-battery][gh].
* Further fixes (avoid_query, report layout, reconnect cache): Conofor
  `<cnfrapp@gmail.com>`.

## License

GPL-2.0-or-later, same as the kernel's `hid-apple.c`.

[lore]: https://lore.kernel.org/linux-input/20260714101235.99447-1-signshop.alec@gmail.com/
[gh]: https://github.com/hall-alec/magic-hid-bt-battery
[companion]: https://github.com/conofor/bluez
