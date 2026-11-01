/* SPDX-License-Identifier: MIT. HORI-compatible Switch HID layout.
   Reference: shinyquagsire23/Switch-Fightstick Descriptors.c, Joystick.h. */
#include "usb.h"
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
static int text(const char *path,char *out,size_t n){FILE *f=fopen(path,"r");if(!f)return -1;int ok=fgets(out,(int)n,f)!=NULL;fclose(f);if(!ok)return -1;out[strcspn(out,"\r\n")]=0;return 0;}
int vgf_usb_configured(void){
    char udc[128],path[256],state[64];
    if(text("/sys/kernel/config/usb_gadget/vgf-controller/UDC",udc,sizeof(udc))||!udc[0])return 0;
    for(char *p=udc;*p;p++)if(!isalnum((unsigned char)*p)&&*p!='.'&&*p!='-'&&*p!='_')return 0;
    snprintf(path,sizeof(path),"/sys/class/udc/%s/state",udc);return !text(path,state,sizeof(state))&&!strcmp(state,"configured");
}
const char *vgf_usb_state(void){
    static char state[64],udc[128],path[256];
    if(text("/sys/kernel/config/usb_gadget/vgf-controller/UDC",udc,sizeof(udc))||!udc[0])return "not attached";
    for(char *p=udc;*p;p++)if(!isalnum((unsigned char)*p)&&*p!='.'&&*p!='-'&&*p!='_')return "unavailable";
    snprintf(path,sizeof(path),"/sys/class/udc/%s/state",udc);
    if(text(path,state,sizeof(state)))return "unavailable";
    return state;
}
int vgf_usb_open(void){
    char path[64];if(text("/run/vgf-hid-device",path,sizeof(path))||strncmp(path,"/dev/hidg",9)||!path[9])return -1;
    for(char *p=path+9;*p;p++)if(!isdigit((unsigned char)*p))return -1;
    if(!vgf_usb_configured())return -1;return open(path,O_RDWR|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
}
void vgf_usb_report(const vgf_input *v,uint8_t out[8]){
    memset(out,0,8);uint16_t b=0;
    const uint8_t bits[]={2,1,3,0,4,5,6,7,9,8,12,13,10,11};
    for(int i=0;i<14;i++)if(v->buttons&(1u<<i))b|=(uint16_t)(1u<<bits[i]);
    out[0]=(uint8_t)b;out[1]=(uint8_t)(b>>8);
    int x=!!(v->buttons&(1u<<RIGHT))-!!(v->buttons&(1u<<LEFT));
    int y=!!(v->buttons&(1u<<DOWN))-!!(v->buttons&(1u<<UP));
    const uint8_t hats[3][3]={{7,0,1},{6,8,2},{5,4,3}};out[2]=hats[y+1][x+1];
    for(int i=0;i<4;i++){
        double a=(double)v->axis[i]/(v->axis[i]<0?32768:32767);if(i&1)a=-a;
        out[3+i]=(uint8_t)lround(128+a*(a<0?128:127));
    }
}
void vgf_usb_descriptor(void){
    /* Sixteen buttons, hat+padding, four 8-bit axes, vendor byte, 8-byte OUT. */
    const unsigned char d[]={
        0x05,0x01,0x09,0x05,0xa1,0x01,0x15,0x00,0x25,0x01,0x35,0x00,0x45,0x01,
        0x75,0x01,0x95,0x10,0x05,0x09,0x19,0x01,0x29,0x10,0x81,0x02,
        0x05,0x01,0x25,0x07,0x46,0x3b,0x01,0x75,0x04,0x95,0x01,0x65,0x14,0x09,0x39,0x81,0x42,
        0x65,0x00,0x95,0x01,0x81,0x01,
        0x26,0xff,0x00,0x46,0xff,0x00,0x09,0x30,0x09,0x31,0x09,0x32,0x09,0x35,0x75,0x08,0x95,0x04,0x81,0x02,
        0x06,0x00,0xff,0x09,0x20,0x95,0x01,0x81,0x02,0x0a,0x21,0x26,0x95,0x08,0x91,0x02,0xc0};
    (void)fwrite(d,1,sizeof(d),stdout);
}
