#!/usr/bin/env python3
# Release the AD2 (FT232H 0403:6014) from the kernel's ftdi_sio serial driver so Chrome's WebUSB can claim it.
# Needed after every replug/reboot: Linux binds ftdi_sio to the FT232H, and WebUSB cannot detach kernel drivers.
# Works as a normal user (needs only access to the device node, as Adept has). Usage: python3 detach.py
import ctypes, sys

lu = ctypes.CDLL('libusb-1.0.so.0')
lu.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
lu.libusb_open_device_with_vid_pid.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16]
for f in ('libusb_kernel_driver_active', 'libusb_detach_kernel_driver'):
    getattr(lu, f).argtypes = [ctypes.c_void_p, ctypes.c_int]
lu.libusb_close.argtypes = [ctypes.c_void_p]

if lu.libusb_init(None): sys.exit('libusb_init failed')
h = lu.libusb_open_device_with_vid_pid(None, 0x0403, 0x6014)
if not h: sys.exit('AD2 (0403:6014) not found, or no permission on its device node')
active = lu.libusb_kernel_driver_active(h, 0)
if active == 1:
    r = lu.libusb_detach_kernel_driver(h, 0)
    print('kernel driver detached' if r == 0 else f'detach failed ({r})')
elif active == 0:
    print('no kernel driver bound: WebUSB can claim it')
else:
    print(f'could not query the kernel driver ({active})')
lu.libusb_close(h)
