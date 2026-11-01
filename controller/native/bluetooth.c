/* SPDX-License-Identifier: MIT. Profile registration mirrors NXBT's BlueZ setup. */
#include "bluetooth.h"
#include <bluetooth/l2cap.h>
#include <bluetooth/hci.h>
#include <bluetooth/hci_lib.h>
#include <linux/rfkill.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int call(DBusConnection *bus,DBusMessage *m) {
    DBusError e;dbus_error_init(&e);
    DBusMessage *r=dbus_connection_send_with_reply_and_block(bus,m,3000,&e);dbus_message_unref(m);
    if(!r){fprintf(stderr,"BlueZ: %s\n",e.message?e.message:"no reply");dbus_error_free(&e);return -1;}
    dbus_message_unref(r);return 0;
}
static int property(DBusConnection *bus,const char *key,int type,const void *v) {
    DBusMessage *m=dbus_message_new_method_call("org.bluez","/org/bluez/hci0","org.freedesktop.DBus.Properties","Set");
    if(!m)return -1;DBusMessageIter i,a;dbus_message_iter_init_append(m,&i);
    const char *iface="org.bluez.Adapter1";char sig[2]={(char)type,0};
    dbus_message_iter_append_basic(&i,DBUS_TYPE_STRING,&iface);dbus_message_iter_append_basic(&i,DBUS_TYPE_STRING,&key);
    dbus_message_iter_open_container(&i,DBUS_TYPE_VARIANT,sig,&a);dbus_message_iter_append_basic(&a,type,v);dbus_message_iter_close_container(&i,&a);
    return call(bus,m);
}
static void option(DBusMessageIter *array,const char *key,int type,const void *v) {
    DBusMessageIter e,a;char sig[2]={(char)type,0};
    dbus_message_iter_open_container(array,DBUS_TYPE_DICT_ENTRY,NULL,&e);dbus_message_iter_append_basic(&e,DBUS_TYPE_STRING,&key);
    dbus_message_iter_open_container(&e,DBUS_TYPE_VARIANT,sig,&a);dbus_message_iter_append_basic(&a,type,v);
    dbus_message_iter_close_container(&e,&a);dbus_message_iter_close_container(array,&e);
}
int vgf_bt_setup(vgf_bt *b,const char *sdp) {
    memset(b,0,sizeof(*b));b->ctrl=b->itr=b->listen_ctrl=b->listen_itr=-1;
    DBusError e;dbus_error_init(&e);b->bus=dbus_bus_get_private(DBUS_BUS_SYSTEM,&e);
    if(!b->bus){dbus_error_free(&e);return -1;}dbus_connection_set_exit_on_disconnect(b->bus,FALSE);
    dbus_bool_t yes=TRUE,no=FALSE;uint32_t zero=0,timeout=180;const char *alias="Pro Controller";
    if(property(b->bus,"Powered",DBUS_TYPE_BOOLEAN,&yes)||property(b->bus,"Pairable",DBUS_TYPE_BOOLEAN,&yes)||
       property(b->bus,"PairableTimeout",DBUS_TYPE_UINT32,&zero)||property(b->bus,"DiscoverableTimeout",DBUS_TYPE_UINT32,&timeout)||
       property(b->bus,"Alias",DBUS_TYPE_STRING,&alias))return -1;
    if(hci_devba(0,&b->local)<0)return -1;
    FILE *f=fopen(sdp,"r");if(!f)return -1;char xml[16384];size_t n=fread(xml,1,sizeof(xml)-1,f);int bad=ferror(f)||!feof(f);fclose(f);if(bad)return -1;xml[n]=0;
    DBusMessage *m=dbus_message_new_method_call("org.bluez","/org/bluez","org.bluez.ProfileManager1","RegisterProfile");if(!m)return -1;
    DBusMessageIter i,a;dbus_message_iter_init_append(m,&i);
    const char *path="/vgf/controller",*uuid="00001000-0000-1000-8000-00805f9b34fb",*record=xml,*role="server";
    dbus_message_iter_append_basic(&i,DBUS_TYPE_OBJECT_PATH,&path);dbus_message_iter_append_basic(&i,DBUS_TYPE_STRING,&uuid);
    dbus_message_iter_open_container(&i,DBUS_TYPE_ARRAY,"{sv}",&a);
    option(&a,"ServiceRecord",DBUS_TYPE_STRING,&record);option(&a,"Role",DBUS_TYPE_STRING,&role);
    option(&a,"RequireAuthentication",DBUS_TYPE_BOOLEAN,&no);option(&a,"RequireAuthorization",DBUS_TYPE_BOOLEAN,&no);option(&a,"AutoConnect",DBUS_TYPE_BOOLEAN,&yes);
    dbus_message_iter_close_container(&i,&a);return call(b->bus,m);
}
static int channel(const bdaddr_t *addr,int psm,int listen_mode) {
    int fd=socket(AF_BLUETOOTH,SOCK_SEQPACKET|SOCK_NONBLOCK|SOCK_CLOEXEC,BTPROTO_L2CAP);if(fd<0)return -1;
    struct sockaddr_l2 sa={.l2_family=AF_BLUETOOTH,.l2_psm=htobs((uint16_t)psm)};bacpy(&sa.l2_bdaddr,addr);
    if(listen_mode){if(bind(fd,(struct sockaddr*)&sa,sizeof(sa))<0||listen(fd,1)<0){close(fd);return -1;}}
    else if(connect(fd,(struct sockaddr*)&sa,sizeof(sa))<0 && errno!=EINPROGRESS){close(fd);return -1;}
    return fd;
}
int vgf_bt_connect(vgf_bt *b,const char *address) {
    if(str2ba(address,&b->remote)<0)return -1;
    b->ctrl=channel(&b->remote,17,0);if(b->ctrl<0)return -1;
    b->itr=channel(&b->remote,19,0);if(b->itr<0){close(b->ctrl);b->ctrl=-1;return -1;}
    b->ctrl_pending=b->itr_pending=1;return 0;
}
int vgf_bt_listen(vgf_bt *b) {
    if(b->ctrl>=0)close(b->ctrl);if(b->itr>=0)close(b->itr);b->ctrl=b->itr=-1;b->ctrl_pending=b->itr_pending=0;
    bacpy(&b->remote,BDADDR_ANY);
    b->listen_ctrl=channel(&b->local,17,1);b->listen_itr=channel(&b->local,19,1);
    if(b->listen_ctrl<0||b->listen_itr<0)return -1;
    dbus_bool_t yes=TRUE;if(property(b->bus,"Discoverable",DBUS_TYPE_BOOLEAN,&yes))return -1;
    int h=hci_open_dev(0);if(h<0)return -1;int r=hci_write_class_of_dev(h,0x002508,1000);close(h);return r;
}
static int accept_one(int listener,int *fd,bdaddr_t *remote) {
    if(*fd>=0)return 0;struct sockaddr_l2 sa;socklen_t n=sizeof(sa);
    int c=accept4(listener,(struct sockaddr*)&sa,&n,SOCK_NONBLOCK|SOCK_CLOEXEC);
    if(c<0)return errno==EAGAIN||errno==EWOULDBLOCK?0:-1;
    if(bacmp(remote,BDADDR_ANY) && bacmp(remote,&sa.l2_bdaddr)){close(c);return 0;}
    bacpy(remote,&sa.l2_bdaddr);*fd=c;return 0;
}
int vgf_bt_accept(vgf_bt *b) {
    if(accept_one(b->listen_ctrl,&b->ctrl,&b->remote)||accept_one(b->listen_itr,&b->itr,&b->remote))return -1;
    return b->ctrl>=0&&b->itr>=0?1:0;
}
int vgf_bt_ready(vgf_bt *b) {
    int fds[]={b->ctrl,b->itr};
    for(int i=0;i<2;i++){int error=0;socklen_t n=sizeof(error);struct sockaddr_l2 peer;socklen_t sz=sizeof(peer);
        if(fds[i]<0)return -1;if(getsockopt(fds[i],SOL_SOCKET,SO_ERROR,&error,&n)<0||error){errno=error;return -1;}
        if(getpeername(fds[i],(struct sockaddr*)&peer,&sz)<0)return 0;
    }
    b->ctrl_pending=b->itr_pending=0;return 1;
}
void vgf_bt_close(vgf_bt *b) {
    int fds[]={b->ctrl,b->itr,b->listen_ctrl,b->listen_itr};for(int i=0;i<4;i++)if(fds[i]>=0)close(fds[i]);
    b->ctrl=b->itr=b->listen_ctrl=b->listen_itr=-1;
    if(b->bus){dbus_connection_close(b->bus);dbus_connection_unref(b->bus);b->bus=NULL;}
}
int vgf_bt_rfkill(int block) {
    int fd=open("/dev/rfkill",O_RDWR|O_NONBLOCK|O_CLOEXEC);if(fd<0)return -1;
    /* Opening queues one ADD event per radio with its current state. */
    struct rfkill_event e;int changed=0;
    while(read(fd,&e,RFKILL_EVENT_SIZE_V1)==RFKILL_EVENT_SIZE_V1)if(e.op==RFKILL_OP_ADD&&e.type==RFKILL_TYPE_BLUETOOTH&&e.soft!=!!block)changed=1;
    if(changed){memset(&e,0,sizeof(e));e.op=RFKILL_OP_CHANGE_ALL;e.type=RFKILL_TYPE_BLUETOOTH;e.soft=(uint8_t)!!block;
        if(write(fd,&e,RFKILL_EVENT_SIZE_V1)!=RFKILL_EVENT_SIZE_V1){int saved=errno;close(fd);errno=saved;return -1;}}
    close(fd);return changed;
}
