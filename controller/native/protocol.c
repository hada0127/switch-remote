/* SPDX-License-Identifier: MIT. See ../vendor/NXBT-LICENSE for protocol provenance. */
#include "protocol.h"
#include <string.h>
#include <math.h>
#include <openssl/hmac.h>
#include <openssl/crypto.h>

void vgf_enqueue(vgf_queue *q,const vgf_input *v,double now) {
    q->last_input=now;
    if(q->count && q->events[(q->head+q->count-1)%VGF_QUEUE_SIZE].input.buttons==v->buttons) {
        --q->count; ++q->coalesced;
    }
    if(q->count==VGF_QUEUE_SIZE) { q->discarded+=q->count;q->head=q->count=0; }
    q->events[(q->head+q->count++)%VGF_QUEUE_SIZE]=(vgf_event){*v,now};
}
vgf_input vgf_next(vgf_queue *q,double now) {
    if(now-q->last_input>.35) { q->head=q->count=0;memset(&q->held,0,sizeof(q->held)); }
    else {
        while(q->count>1 && now-q->events[q->head].received>.1) { q->head=(q->head+1)%VGF_QUEUE_SIZE;--q->count;++q->discarded; }
        if(q->count) { q->held=q->events[q->head].input;q->head=(q->head+1)%VGF_QUEUE_SIZE;--q->count; }
    }
    return q->held;
}
int vgf_decode(const uint8_t *p,size_t n,const uint8_t key[32],uint64_t *last,vgf_input *out) {
    if(n!=VGF_PACKET_SIZE || memcmp(p+8,"VGF2",4))return -1;
    uint8_t tag[32];unsigned int len=0;
    if(!HMAC(EVP_sha256(),key,32,p,24,tag,&len)||len!=32||CRYPTO_memcmp(tag,p+24,32))return -1;
    uint64_t seq=0;for(int i=0;i<8;i++)seq=(seq<<8)|p[i];if(seq<=*last)return -1;
    vgf_input v={0};for(int i=0;i<4;i++)v.buttons|=(uint32_t)p[12+i]<<(8*i);
    if(v.buttons>>VGF_BUTTONS)return -1;
    for(int i=0;i<4;i++){uint16_t u=p[16+i*2]|((uint16_t)p[17+i*2]<<8);v.axis[i]=u<=32767?(int16_t)u:(int16_t)((int32_t)u-65536);}
    *out=v;*last=seq;return 0;
}
void vgf_ack(const uint8_t key[32],uint64_t seq,uint8_t out[VGF_ACK_SIZE]) {
    for(int i=7;i>=0;i--){out[i]=(uint8_t)seq;seq>>=8;}
    memcpy(out+8,"VGFA",4);unsigned int len=0;
    if(!HMAC(EVP_sha256(),key,32,out,12,out+12,&len)||len!=32)memset(out+12,0,32);
}
static void stick(uint8_t *out,int16_t x,int16_t y,int cx,int cy,int negx,int posx,int negy,int posy) {
    int xx=cx+(int)lround((double)x*(x<0?negx:posx)/(x<0?32768:32767));
    int yy=cy+(int)lround((double)y*(y<0?negy:posy)/(y<0?32768:32767));
    out[0]=(uint8_t)xx;out[1]=(uint8_t)((xx>>8)|((yy&15)<<4));out[2]=(uint8_t)(yy>>4);
}
static uint8_t spi(uint32_t a) {
    static const uint8_t params[]={0x0f,0x30,0x61,0x96,0x30,0xf3,0xd4,0x14,0x54,0x41,0x15,0x54,0xc7,0x79,0x9c,0x33,0x36,0x63};
    static const uint8_t sticks[]={0xba,0xf5,0x62,0x6f,0xc8,0x77,0xed,0x95,0x5b,0x16,0xd8,0x7d,0xf2,0xb5,0x5f,0x86,0x65,0x5e};
    static const uint8_t sensor[]={0xd3,0xff,0xd5,0xff,0x55,1,0,0x40,0,0x40,0,0x40,0x19,0,0xdd,0xff,0xdc,0xff,0x3b,0x34,0x3b,0x34,0x3b,0x34};
    static const uint8_t factory[]={0x50,0xfd,0,0,0xc6,0x0f};
    if(a>=0x603d && a<0x603d+sizeof(sticks))return sticks[a-0x603d];
    if(a>=0x6020 && a<0x6020+sizeof(sensor))return sensor[a-0x6020];
    if(a>=0x6080 && a<0x6086)return factory[a-0x6080];
    if(a>=0x6086 && a<0x6098)return params[a-0x6086];
    if(a>=0x6098 && a<0x60aa)return params[a-0x6098];
    if(a>=0x6050 && a<0x6053)return 0x82;
    if(a>=0x6053 && a<0x6056)return 0x0f;
    return 0xff;
}
void vgf_report(vgf_protocol *p,const vgf_input *v,const uint8_t *in,size_t n,double now,uint8_t out[50]) {
    memset(out,0,50);out[0]=0xa1;out[1]=0x30;
    if(p->last_report>0)p->timer=(uint8_t)(p->timer+(unsigned)((now-p->last_report)*4000));
    p->last_report=now;out[2]=p->timer;out[3]=0x90;out[13]=0xa0;
    const uint8_t byte[]={4,4,4,4,6,4,6,4,5,5,5,5,5,5,6,6,6,6};
    const uint8_t bit[]={3,2,1,0,6,6,7,7,1,0,4,5,3,2,1,0,3,2};
    for(unsigned i=0;i<VGF_BUTTONS;i++)if(v->buttons&(1u<<i))out[byte[i]]|=(uint8_t)(1u<<bit[i]);
    stick(out+7,v->axis[0],v->axis[1],2159,1916,1517,1466,1465,1583);
    stick(out+10,v->axis[2],v->axis[3],2070,2013,1522,1414,1531,1510);
    if(in && n>=12 && in[0]==0xa2 && in[1]==1) {
        uint8_t cmd=in[11];out[1]=0x21;out[14]=0x80;out[15]=cmd;
        switch(cmd) {
        case 2: p->device_info=true;out[14]=0x82;out[16]=3;out[17]=0x8b;out[18]=3;out[19]=2;memcpy(out+20,p->address,6);out[26]=out[27]=1;break;
        case 3: if(n>=13)p->mode=in[12];break;
        case 4: out[14]=0x83;break;
        case 0x10:
            if(n<17){out[14]=0;break;}
            { uint32_t a=0;for(int i=0;i<4;i++)a|=(uint32_t)in[12+i]<<(8*i);
              unsigned len=in[16];if(len>29){out[14]=0;break;}
              out[14]=0x90;memcpy(out+16,in+12,4);out[20]=(uint8_t)len;
              for(unsigned i=0;i<len;i++)out[21+i]=spi(a+i); }
            break;
        case 0x21:{const uint8_t data[]={1,0,0xff,0,8,0,0x1b,1};out[14]=0xa0;memcpy(out+16,data,8);out[49]=0xc8;break;}
        case 0x30:if(n>=13)p->player=in[12];break;
        case 0x40:if(n>=13)p->imu=in[12]!=0;break;
        case 0x48:out[14]=0x82;p->vibration=true;break;
        case 8:case 0x22:case 0x38:case 0x41:break;
        default:out[1]=0x30;out[14]=out[15]=0;break;
        }
    } else if(p->imu) {
        /* Stationary IMU, not motion emulation. Three identical samples. */
        const uint8_t sample[]={0x75,0xfd,0xfd,0xff,9,0x10,0x21,0,0xd5,0xff,0xe0,0xff};
        for(int i=0;i<3;i++)memcpy(out+14+12*i,sample,12);
    }
}

/* During pairing, avoid flooding the Switch grip/order screen. */
double vgf_report_interval(const vgf_protocol *p, int usb){return usb?.008:(p->vibration&&p->player?.015:.066);}
