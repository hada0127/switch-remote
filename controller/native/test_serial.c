#include "serial.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <poll.h>
#include <unistd.h>
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
                if(vgf_serial_byte(&parser,bytes[i],&input,&seq)!=1)continue;
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
    vgf_serial_parser parser={0};uint64_t seq=0;
    assert(vgf_serial_byte(&parser,0x33,&decoded,&seq)==0);
    for(size_t i=0;i<sizeof(frame)-1;i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq)==0);
    assert(vgf_serial_byte(&parser,frame[sizeof(frame)-1],&decoded,&seq)==1);
    assert(seq==9&&decoded.buttons==input.buttons&&!memcmp(decoded.axis,input.axis,sizeof(input.axis)));
    for(size_t i=0;i<sizeof(frame);i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq)<=0);
    frame[18]^=1;for(size_t i=0;i<sizeof(frame);i++)assert(vgf_serial_byte(&parser,frame[i],&decoded,&seq)<=0);
    uint8_t ack[VGF_SERIAL_ACK];vgf_serial_ack(9,ack);assert(ack[2]==8&&vgf_serial_crc(ack+2,9)==(uint16_t)(ack[11]|ack[12]<<8));
    puts("PASS serial frame CRC, parser, duplicate, corruption, ack");return 0;
}
