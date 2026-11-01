#include "serial.h"
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

/* CRC-16/CCITT-FALSE, initial 0xffff, over length through payload. */
uint16_t vgf_serial_crc(const uint8_t *p,size_t n){uint16_t c=0xffff;for(size_t i=0;i<n;i++){c^=(uint16_t)p[i]<<8;for(int b=0;b<8;b++)c=(uint16_t)((c<<1)^((c&0x8000)?0x1021:0));}return c;}
static void sequence_bytes(uint64_t seq,uint8_t *p){for(int i=7;i>=0;i--){p[i]=(uint8_t)seq;seq>>=8;}}
void vgf_serial_frame(uint64_t seq,const vgf_input *v,uint8_t out[VGF_SERIAL_INPUT]){
    out[0]=0xa5;out[1]=0x5a;out[2]=24;sequence_bytes(seq,out+3);memcpy(out+11,"VGF2",4);
    for(int i=0;i<4;i++)out[15+i]=(uint8_t)(v->buttons>>(8*i));
    for(int i=0;i<4;i++){uint16_t axis=(uint16_t)v->axis[i];out[19+i*2]=(uint8_t)axis;out[20+i*2]=(uint8_t)(axis>>8);}
    uint16_t crc=vgf_serial_crc(out+2,25);out[27]=(uint8_t)crc;out[28]=(uint8_t)(crc>>8);
}
int vgf_serial_byte(vgf_serial_parser *s,uint8_t b,vgf_input *out,uint64_t *seq){
    if(!s->used){if(b==0xa5)s->bytes[s->used++]=b;return 0;}
    if(s->used==1){if(b==0x5a)s->bytes[s->used++]=b;else s->used=b==0xa5?1:0;return 0;}
    s->bytes[s->used++]=b;
    if(s->used==3&&b!=24){s->used=b==0xa5?1:0;return -1;}
    if(s->used<VGF_SERIAL_INPUT)return 0;
    s->used=0;uint16_t crc=vgf_serial_crc(s->bytes+2,25);
    if(s->bytes[27]!=(uint8_t)crc||s->bytes[28]!=(uint8_t)(crc>>8)||memcmp(s->bytes+11,"VGF2",4))return -1;
    uint64_t number=0;for(int i=3;i<11;i++)number=(number<<8)|s->bytes[i];
    uint32_t buttons=0;for(int i=0;i<4;i++)buttons|=(uint32_t)s->bytes[15+i]<<(8*i);
    if(!number||number<=s->last||buttons>>VGF_BUTTONS)return -1;
    vgf_input v={.buttons=buttons};for(int i=0;i<4;i++){uint16_t u=s->bytes[19+i*2]|((uint16_t)s->bytes[20+i*2]<<8);v.axis[i]=(int16_t)u;}
    s->last=number;*seq=number;*out=v;return 1;
}
void vgf_serial_ack(uint64_t seq,uint8_t out[VGF_SERIAL_ACK]){
    out[0]=0xa5;out[1]=0x5a;out[2]=8;sequence_bytes(seq,out+3);
    uint16_t crc=vgf_serial_crc(out+2,9);out[11]=(uint8_t)crc;out[12]=(uint8_t)(crc>>8);
}
int vgf_serial_open(const char *path){
    int fd=open(path,O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC);if(fd<0)return -1;
    struct termios t;if(tcgetattr(fd,&t)<0){close(fd);return -1;}cfmakeraw(&t);
    cfsetispeed(&t,B115200);cfsetospeed(&t,B115200);t.c_cflag|=CLOCAL|CREAD;t.c_cflag&=~CRTSCTS;
    t.c_cc[VMIN]=0;t.c_cc[VTIME]=0;
    if(tcsetattr(fd,TCSANOW,&t)<0||tcflush(fd,TCIOFLUSH)<0){close(fd);return -1;}
    return fd;
}
