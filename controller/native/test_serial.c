#include "serial.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <poll.h>
#include <unistd.h>
static void hex_frame(const uint8_t *b,size_t n,char *out){for(size_t i=0;i<n;i++)sprintf(out+i*2,"%02x",b[i]);out[n*2]=0;}
static void put32(uint8_t *p,uint32_t v){p[0]=(uint8_t)(v>>24);p[1]=(uint8_t)(v>>16);p[2]=(uint8_t)(v>>8);p[3]=(uint8_t)v;}
static void golden(uint8_t type,const uint8_t body[VGF_SERIAL_BODY],const char *expected){
    uint8_t frame[VGF_SERIAL_CONTROL];char text[VGF_SERIAL_CONTROL*2+1];
    vgf_serial_control_frame(type,body,frame);hex_frame(frame,sizeof(frame),text);
    if(strcmp(text,expected)){fprintf(stderr,"golden mismatch type %02x\n got %s\nwant %s\n",type,text,expected);assert(0);}
    /* Round trip through the parser, which must not touch the input sequence. */
    vgf_serial_parser parser={.last=77};vgf_serial_control c;vgf_input input;uint64_t seq=0;
    for(size_t i=0;i<sizeof(frame)-1;i++)assert(vgf_serial_byte(&parser,frame[i],&input,&seq,&c)==0);
    assert(vgf_serial_byte(&parser,frame[sizeof(frame)-1],&input,&seq,&c)==2);
    assert(c.type==type&&!memcmp(c.body,body,VGF_SERIAL_BODY)&&parser.last==77&&seq==0);
    /* A NULL control consumes the frame without reporting it. */
    for(size_t i=0;i<sizeof(frame);i++)assert(vgf_serial_byte(&parser,frame[i],&input,&seq,NULL)==0);
    /* Any corrupted byte after the length is rejected by CRC. */
    for(size_t at=3;at<sizeof(frame);at++){
        uint8_t bad[VGF_SERIAL_CONTROL];memcpy(bad,frame,sizeof(bad));bad[at]^=0x10;int last=0;
        vgf_serial_parser p={0};for(size_t i=0;i<sizeof(bad);i++){last=vgf_serial_byte(&p,bad[i],&input,&seq,&c);assert(last!=2);}
        assert(last==-1);
    }
}
static void golden_vectors(void){
    const uint8_t id[16]={0x11,0x11,0x11,0x11,0x22,0x22,0x33,0x33,0x44,0x44,0x55,0x55,0x55,0x55,0x55,0x55};
    uint8_t b[VGF_SERIAL_BODY];
    memset(b,0,sizeof(b));b[0]=VGF_SERIAL_VERSION;put32(b+1,0x01020304);
    golden(VGF_SERIAL_HELLO,b,"a55a1a0101010203040000000000000000000000000000000000000000fd7a");
    memset(b,0,sizeof(b));put32(b,7);b[4]=VGF_SERIAL_USB_DETACH;
    golden(VGF_SERIAL_USB,b,"a55a1a0200000007010000000000000000000000000000000000000000d233");
    memset(b,0,sizeof(b));put32(b,0x01020304);
    golden(VGF_SERIAL_BYE,b,"a55a1a03010203040000000000000000000000000000000000000000008278");
    memset(b,0,sizeof(b));b[0]=VGF_SERIAL_VERSION;b[1]=VGF_SERIAL_HELLO_OK;put32(b+2,0x01020304);memcpy(b+6,id,16);
    golden(VGF_SERIAL_HELLO_REPLY,b,"a55a1a8101000102030411111111222233334444555555555555000000614d");
    memset(b,0,sizeof(b));b[0]=VGF_SERIAL_CONNECTED;b[1]=VGF_SERIAL_BACKEND_USB;memcpy(b+2,"configured",10);
    golden(VGF_SERIAL_STATUS,b,"a55a1a820301636f6e66696775726564000000000000000000000000005751");
    memset(b,0,sizeof(b));put32(b,7);b[4]=VGF_SERIAL_USB_ACCEPTED;
    golden(VGF_SERIAL_USB_RESULT,b,"a55a1a8300000007000000000000000000000000000000000000000000f640");
    memset(b,0,sizeof(b));put32(b,0x01020304);b[4]=VGF_SERIAL_BYE_ATTACH;
    golden(VGF_SERIAL_PI_BYE,b,"a55a1a840102030401000000000000000000000000000000000000000083d2");
    /* Every type round-trips with arbitrary body bytes, including an unknown type. */
    const uint8_t types[]={VGF_SERIAL_HELLO,VGF_SERIAL_USB,VGF_SERIAL_BYE,VGF_SERIAL_HELLO_REPLY,VGF_SERIAL_STATUS,VGF_SERIAL_USB_RESULT,VGF_SERIAL_PI_BYE,0x7f};
    for(size_t t=0;t<sizeof(types);t++){
        for(int i=0;i<VGF_SERIAL_BODY;i++)b[i]=(uint8_t)(i*37+t*11+0xa5);
        uint8_t frame[VGF_SERIAL_CONTROL];vgf_serial_control_frame(types[t],b,frame);
        vgf_serial_parser p={0};vgf_serial_control c;vgf_input input;uint64_t seq;int r=0;
        for(size_t i=0;i<sizeof(frame);i++)r=vgf_serial_byte(&p,frame[i],&input,&seq,&c);
        assert(r==2&&c.type==types[t]&&!memcmp(c.body,b,VGF_SERIAL_BODY));
    }
    /* A NULL body sends zeros. */
    uint8_t zero[VGF_SERIAL_BODY]={0},a[VGF_SERIAL_CONTROL],z[VGF_SERIAL_CONTROL];
    vgf_serial_control_frame(VGF_SERIAL_BYE,NULL,a);vgf_serial_control_frame(VGF_SERIAL_BYE,zero,z);assert(!memcmp(a,z,sizeof(a)));
}
static void mixed_stream(void){
    /* Garbage, an echoed LEN 8 ack, inputs, and controls interleave. */
    uint8_t stream[256];size_t n=0;vgf_input in={.buttons=1u<<B};
    const uint8_t junk[]={0x00,0xa5,0x13,0xa5,0xa5,0x5a,0x07,0xff};memcpy(stream+n,junk,sizeof(junk));n+=sizeof(junk);
    uint8_t ack[VGF_SERIAL_ACK];vgf_serial_ack(5,ack);memcpy(stream+n,ack,sizeof(ack));n+=sizeof(ack);
    vgf_serial_frame(3,&in,stream+n);n+=VGF_SERIAL_INPUT;
    uint8_t body[VGF_SERIAL_BODY]={0};put32(body,9);body[4]=VGF_SERIAL_USB_ATTACH;
    vgf_serial_control_frame(VGF_SERIAL_USB,body,stream+n);n+=VGF_SERIAL_CONTROL;
    vgf_serial_frame(4,&in,stream+n);n+=VGF_SERIAL_INPUT;
    vgf_serial_control_frame(VGF_SERIAL_BYE,NULL,stream+n);n+=VGF_SERIAL_CONTROL;
    vgf_serial_frame(6,&in,stream+n);n+=VGF_SERIAL_INPUT;
    assert(n<=sizeof(stream));
    vgf_serial_parser p={0};vgf_serial_control c;vgf_input out;uint64_t seq=0,previous=0;
    unsigned inputs=0,controls=0,invalid=0;uint8_t seen[2]={0};
    for(size_t i=0;i<n;i++){
        int r=vgf_serial_byte(&p,stream[i],&out,&seq,&c);
        if(r<0)invalid++;
        /* Controls between inputs leave the sequence strictly increasing. */
        if(r==1){assert(seq>previous&&out.buttons==in.buttons);previous=seq;inputs++;}
        if(r==2){assert(controls<2);seen[controls++]=c.type;}
    }
    assert(inputs==3&&previous==6&&controls==2&&seen[0]==VGF_SERIAL_USB&&seen[1]==VGF_SERIAL_BYE&&invalid>=1);
    /* With control NULL the same stream yields the same inputs and no control result. */
    vgf_serial_parser q={0};inputs=0;
    for(size_t i=0;i<n;i++){int r=vgf_serial_byte(&q,stream[i],&out,&seq,NULL);assert(r!=2);if(r==1)inputs++;}
    assert(inputs==3);
    /* The Pi side rejects a LEN 8 frame at its third byte. */
    vgf_serial_parser a={0};assert(vgf_serial_byte(&a,ack[0],&out,&seq,&c)==0);assert(vgf_serial_byte(&a,ack[1],&out,&seq,&c)==0);
    assert(vgf_serial_byte(&a,ack[2],&out,&seq,&c)==-1);
}
int main(int argc,char **argv){
    if(argc==3 && !strcmp(argv[1],"--probe")){
        int fd=vgf_serial_open(argv[2]);if(fd<0){perror("open serial");return 2;}
        puts("serial_probe_ready");fflush(stdout);
        vgf_serial_parser parser={0};unsigned received=0;
        while(received<20){
            struct pollfd p={fd,POLLIN,0};if(poll(&p,1,5000)!=1)break;
            uint8_t bytes[128];ssize_t n=read(fd,bytes,sizeof(bytes));
            for(ssize_t i=0;i<n;i++){
                vgf_input input;uint64_t seq;
                if(vgf_serial_byte(&parser,bytes[i],&input,&seq,NULL)!=1)continue;
                uint8_t ack[VGF_SERIAL_ACK];vgf_serial_ack(seq,ack);
                if(write(fd,ack,sizeof(ack))!=(ssize_t)sizeof(ack)){close(fd);return 3;}
                received++;
            }
        }
        close(fd);printf("serial_probe_frames=%u\n",received);return received==20?0:1;
    }

    assert(vgf_serial_crc((const uint8_t*)"123456789",9)==0x29b1);
    vgf_input input={.buttons=1u<<A|1u<<HOME,.axis={-32768,32767,-1,1}}, decoded={0};
    uint8_t frame[VGF_SERIAL_INPUT];vgf_serial_frame(9,&input,frame);
    assert(frame[0]==0xa5&&frame[1]==0x5a&&frame[2]==24);
    vgf_serial_parser parser={0};uint64_t seq=0;vgf_serial_control control;
    assert(vgf_serial_byte(&parser,0x33,&decoded,&seq,&control)==0);
    for(size_t i=0;i<sizeof(frame)-1;i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq,&control)==0);
    assert(vgf_serial_byte(&parser,frame[sizeof(frame)-1],&decoded,&seq,&control)==1);
    assert(seq==9&&decoded.buttons==input.buttons&&!memcmp(decoded.axis,input.axis,sizeof(input.axis)));
    for(size_t i=0;i<sizeof(frame);i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq,&control)<=0);
    frame[18]^=1;for(size_t i=0;i<sizeof(frame);i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq,&control)<=0);
    uint8_t ack[VGF_SERIAL_ACK];vgf_serial_ack(9,ack);assert(ack[2]==8&&vgf_serial_crc(ack+2,9)==(uint16_t)(ack[11]|ack[12]<<8));
    golden_vectors();mixed_stream();
    puts("PASS serial frame CRC, parser, duplicate, corruption, ack, control golden vectors, round trip, mixed-stream resync");return 0;
}
