/* SPDX-License-Identifier: MIT */
#ifndef VGF_USB_H
#define VGF_USB_H
#include "protocol.h"
int vgf_usb_open(void);
int vgf_usb_configured(void);
const char *vgf_usb_state(void);
void vgf_usb_report(const vgf_input *,uint8_t out[8]);
void vgf_usb_descriptor(void);
#endif
