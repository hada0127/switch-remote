/* SPDX-License-Identifier: MIT */
#include "protocol.h"
#include "usb.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <openssl/hmac.h>
#include <time.h>
static void sign_packet(uint8_t p[56],uint8_t key[32]){unsigned n=0;assert(HMAC(EVP_sha256(),key,32,p,24,p+24,&n));assert(n==32);}
int main(void){
    vgf_input a={.buttons=1u<<A},ab={.buttons=(1u<<A)|(1u<<B)},b={.buttons=1u<<B},zero={0};vgf_queue q={0};
    vgf_enqueue(&q,&a,1);a.axis[0]=123;vgf_enqueue(&q,&a,1.001);vgf_enqueue(&q,&ab,1.002);vgf_enqueue(&q,&b,1.003);vgf_enqueue(&q,&zero,1.004);
    vgf_input v=vgf_next(&q,1.01);assert(v.buttons==(1u<<A)&&v.axis[0]==123);
    assert(vgf_next(&q,1.02).buttons==ab.buttons);assert(vgf_next(&q,1.03).buttons==b.buttons);assert(vgf_next(&q,1.04).buttons==0);
    for(int i=0;i<100;i++){vgf_enqueue(&q,&ab,2+i*.1);assert(vgf_next(&q,2+i*.1+.09).buttons==ab.buttons);}
    assert(vgf_next(&q,12.3).buttons==0);
    for(int i=0;i<100;i++)vgf_enqueue(&q,i%2?&a:&zero,20+i*.001);
    assert(q.count<=32);assert(vgf_next(&q,20.3).buttons==a.buttons);assert(q.count==0);assert(vgf_next(&q,20.5).buttons==0);
    uint8_t p[56]={0},key[32];memset(key,'k',32);p[7]=42;memcpy(p+8,"VGF2",4);p[12]=3;p[16]=0;p[17]=0x80;p[18]=0xff;p[19]=0x7f;sign_packet(p,key);
    uint64_t seq=0;assert(vgf_decode(p,56,key,&seq,&v)==0&&seq==42&&v.buttons==3&&v.axis[0]==-32768&&v.axis[1]==32767);
    assert(vgf_decode(p,56,key,&seq,&v)<0);seq=0;p[12]^=1;assert(vgf_decode(p,56,key,&seq,&v)<0&&seq==0);p[12]^=1;
    for(size_t n=0;n<56;n++)assert(vgf_decode(p,n,key,&seq,&v)<0);
    p[15]=0x80;sign_packet(p,key);assert(vgf_decode(p,56,key,&seq,&v)<0);p[15]=0;sign_packet(p,key);
    /* Shared 44-byte vector with Swift's testAckWireLayoutMatchesNativeVector. */
    uint8_t ack[VGF_ACK_SIZE];vgf_ack(key,42,ack);const uint8_t ack_vector[VGF_ACK_SIZE]={0,0,0,0,0,0,0,42,'V','G','F','A',
        0xe3,0x8b,0x9b,0x11,0x20,0x8a,0x05,0x3c,0xbd,0xee,0x32,0xca,0xae,0x1d,0x44,0xda,0x5f,0x02,0x53,0xa8,
        0x4a,0x10,0x59,0x71,0x8a,0x8f,0x74,0x74,0xd3,0x2e,0xb3,0x80};
    assert(!memcmp(ack,ack_vector,VGF_ACK_SIZE));
    vgf_protocol proto={.address={1,2,3,4,5,6}};uint8_t r[50],in[50]={0xa2,1};
    assert(vgf_report_interval(&proto,0)==.066);assert(vgf_report_interval(&proto,1)==.008);
    proto.vibration=true;assert(vgf_report_interval(&proto,0)==.066);proto.player=1;assert(vgf_report_interval(&proto,0)==.015);
    vgf_report(&proto,&zero,NULL,0,1,r);assert(r[0]==0xa1&&r[1]==0x30);const uint8_t centers[]={0x6f,0xc8,0x77,0x16,0xd8,0x7d};assert(!memcmp(r+7,centers,6));
    v.buttons=(1u<<PLUS)|(1u<<HOME)|(1u<<A)|(1u<<LEFT);memset(v.axis,0,sizeof(v.axis));vgf_report(&proto,&v,NULL,0,1.008,r);assert(r[4]==8&&r[5]==0x12&&r[6]==8);
    in[11]=2;vgf_report(&proto,&zero,in,sizeof(in),2,r);assert(r[14]==0x82&&r[18]==3&&!memcmp(r+20,proto.address,6));
    in[11]=0x10;in[12]=0x3d;in[13]=0x60;in[16]=18;vgf_report(&proto,&zero,in,50,3,r);assert(r[14]==0x90&&r[20]==18&&r[21]==0xba&&r[30]==0x16);
    for(int len=0;len<256;len++){in[16]=(uint8_t)len;vgf_report(&proto,&zero,in,50,4+len*.008,r);assert(len<=29?r[14]==0x90:r[14]==0);}
    uint8_t u[8];vgf_usb_report(&zero,u);const uint8_t neutral[]={0,0,8,128,128,128,128,0};assert(!memcmp(u,neutral,8));
    v.buttons=(1u<<A)|(1u<<B)|(1u<<HOME)|(1u<<UP)|(1u<<RIGHT);v.axis[0]=-32768;v.axis[1]=32767;v.axis[2]=32767;v.axis[3]=-32768;vgf_usb_report(&v,u);
    assert(u[0]==6&&u[1]==0x10&&u[2]==1&&u[3]==0&&u[4]==0&&u[5]==255&&u[6]==255);
    double samples[10000];struct timespec start,end;
    for(int i=0;i<10000;i++){seq=0;clock_gettime(CLOCK_MONOTONIC,&start);assert(vgf_decode(p,56,key,&seq,&v)==0);vgf_report(&proto,&v,NULL,0,100+i*.008,r);vgf_ack(key,seq,ack);clock_gettime(CLOCK_MONOTONIC,&end);samples[i]=(end.tv_sec-start.tv_sec)*1e6+(end.tv_nsec-start.tv_nsec)/1e3;}
    /* Insertion sort only after measurement. */
    for(int i=1;i<10000;i++){double x=samples[i];int j=i;while(j&&samples[j-1]>x){samples[j]=samples[j-1];j--;}samples[j]=x;}
    printf("PASS protocol, HMAC/replay, ack vector, chords, hold/release, bounded queue, SPI bounds, USB report\n");
    printf("decode+BT report+ack CPU time us: p50=%.2f p95=%.2f p99=%.2f max=%.2f (10000 samples; excludes network/USB/BT delivery)\n",samples[5000],samples[9500],samples[9900],samples[9999]);
    return 0;
}
