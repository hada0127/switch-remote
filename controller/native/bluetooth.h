/* SPDX-License-Identifier: MIT */
#ifndef VGF_BLUETOOTH_H
#define VGF_BLUETOOTH_H
#include <dbus/dbus.h>
#include <bluetooth/bluetooth.h>
typedef struct { DBusConnection *bus; bdaddr_t local,remote; int ctrl,itr,listen_ctrl,listen_itr; int ctrl_pending,itr_pending; } vgf_bt;
int vgf_bt_setup(vgf_bt *,const char *sdp);
int vgf_bt_connect(vgf_bt *,const char *address);
int vgf_bt_listen(vgf_bt *);
int vgf_bt_accept(vgf_bt *);
int vgf_bt_ready(vgf_bt *);
void vgf_bt_close(vgf_bt *);
/* Soft-block (1) or unblock (0) every Bluetooth radio: 1 changed, 0 unchanged, -1 error. */
int vgf_bt_rfkill(int block);
#endif
