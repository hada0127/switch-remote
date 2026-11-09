/* SPDX-License-Identifier: MIT. Run production session/cleanup against socket
   backpressure. Only the TLS and gadget entry points are replaced; no live HID,
   enrollment state, or service lock is accessed. */
#include <openssl/ssl.h>
#include <fcntl.h>
#include <stdarg.h>
#include <assert.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <poll.h>
#include "protocol.h"
#include "serial.h"
#include "bluetooth.h"

static int test_tcp=-1,test_hid=-1,test_hid_peer=-1,test_serial=-1,test_serial_fd=-1,test_bt_connected=0;
static double now_s(void);
static int *usb_ready;
static char test_lock[]="/tmp/vgf-session-XXXXXX",test_serial_lock[]="/tmp/vgf-serial-lock-XXXXXX";
static int isolated_open(const char *path,int flags,...){
    mode_t mode=0;
    if(flags&O_CREAT){va_list ap;va_start(ap,flags);mode=va_arg(ap,int);va_end(ap);}
    if(!strcmp(path,"/run/videogamefilter-controller.lock"))path=test_lock;
    if(!strcmp(path,"/run/vgf-serial.lock"))path=test_serial_lock;
    return open(path,flags,mode);
}
static int socket_usb_open(void){return (!usb_ready||*usb_ready)?test_hid:-1;}
/* Each open hands out a dup, as closing and reopening the real uart would. */
static int socket_serial_open(const char *path){(void)path;test_serial_fd=test_serial>=0?dup(test_serial):-1;return test_serial_fd;}
static int socket_usb_configured(void){return !usb_ready||*usb_ready;}
static int waiting_bt_setup(vgf_bt *b,const char *sdp){(void)sdp;b->ctrl=b->itr=b->listen_ctrl=b->listen_itr=-1;b->bus=NULL;return 0;}
static int waiting_bt_connect(vgf_bt *b,const char *address){(void)b;(void)address;return -1;}
static int waiting_bt_listen(vgf_bt *b){(void)b;return 0;}
static int waiting_bt_accept(vgf_bt *b){if(!test_bt_connected)return 0;b->itr=test_hid;return 1;}
static void waiting_bt_close(vgf_bt *b){(void)b;}
static int usb_command_record=0;static unsigned detach_count,attach_count;
static int checked_usb_command(const char *action){
    if(usb_command_record){if(!strcmp(action,"detach"))detach_count++;else if(!strcmp(action,"attach"))attach_count++;else assert(0);return 0;}
    assert(!strcmp(action,"attach"));
    uint8_t report[50];double deadline=now_s()+.5;
    while(now_s()<deadline){
        struct pollfd p={test_hid_peer,POLLIN,0};if(poll(&p,1,20)<=0)continue;
        assert(read(test_hid_peer,report,sizeof(report))==sizeof(report));
        if(!(report[4]&(1u<<3)))return 0; /* Neutral arrived before helper work. */
    }
    assert(0 && "Bluetooth neutral was not sent before USB attach");return -1;
}
static int rfkill_blocked=-1;
static int recorded_rfkill(int block){rfkill_blocked=block;return 1;}
/* Order of the first HID write of `watched` and the first ack datagram. */
static uint8_t watched[8];static unsigned order,hid_at,ack_at,serial_at;
static ssize_t ordered_write(int fd,const void *b,size_t n){ssize_t r=write(fd,b,n);if(fd==test_hid&&r==8&&!memcmp(b,watched,8)&&!hid_at)hid_at=++order;if(fd>=0&&fd==test_serial_fd&&r==VGF_SERIAL_ACK&&!serial_at)serial_at=++order;return r;}
static ssize_t ordered_sendto(int fd,const void *b,size_t n,int f,const struct sockaddr *a,socklen_t l){ssize_t r=sendto(fd,b,n,f,a,l);if(r==VGF_ACK_SIZE&&!ack_at)ack_at=++order;return r;}
/* Cable control (tcp<0) must never reach an SSL call: real OpenSSL would crash on NULL. */
static int plain_write(SSL *ssl,const void *data,int n){(void)ssl;assert(test_tcp>=0);return (int)send(test_tcp,data,(size_t)n,MSG_NOSIGNAL);}
static int plain_read(SSL *ssl,void *data,int n){(void)ssl;assert(test_tcp>=0);return (int)recv(test_tcp,data,(size_t)n,0);}
static int plain_pending(const SSL *ssl){(void)ssl;assert(test_tcp>=0);return 0;}
static int plain_error(const SSL *ssl,int n){(void)ssl;assert(test_tcp>=0);return n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)?SSL_ERROR_WANT_READ:SSL_ERROR_ZERO_RETURN;}

#define main daemon_main_for_test
#define open isolated_open
#define vgf_usb_open socket_usb_open
#define vgf_serial_open socket_serial_open
#define vgf_usb_configured socket_usb_configured
#define vgf_bt_rfkill recorded_rfkill
#define vgf_bt_setup waiting_bt_setup
#define vgf_bt_connect waiting_bt_connect
#define vgf_bt_listen waiting_bt_listen
#define vgf_bt_accept waiting_bt_accept
#define vgf_bt_close waiting_bt_close
#define VGF_USB_COMMAND checked_usb_command
#define write ordered_write
#define sendto ordered_sendto
#define SSL_write plain_write
#define SSL_read plain_read
#define SSL_pending plain_pending
#define SSL_get_error plain_error
#include "service.c"
#undef main
#undef open
#undef vgf_usb_open
#undef vgf_serial_open
#undef vgf_usb_configured
#undef vgf_bt_rfkill
#undef vgf_bt_setup
#undef vgf_bt_connect
#undef vgf_bt_listen
#undef vgf_bt_accept
#undef vgf_bt_close
#undef VGF_USB_COMMAND
#undef write
#undef sendto
#undef SSL_write
#undef SSL_read
#undef SSL_pending
#undef SSL_get_error

static void socket_hid(int fds[2]){
    assert(socketpair(AF_UNIX,SOCK_SEQPACKET,0,fds)==0);
    int size=1024;assert(setsockopt(fds[0],SOL_SOCKET,SO_SNDBUF,&size,sizeof(size))==0);
    assert(set_nonblocking(fds[0])==0);
}
static unsigned fill_hid(int fd){
    const uint8_t filler[8]={0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa};
    unsigned count=0;
    while(write(fd,filler,sizeof(filler))==sizeof(filler))count++;
    assert(count>0&&(errno==EAGAIN||errno==EWOULDBLOCK));return count;
}
static void wait_child(pid_t child){int status;assert(waitpid(child,&status,0)==child);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);}
static void read_transport(int tcp,unsigned char key[32],struct sockaddr_in *peer){
    char line[512];
    for(;;){
        size_t used=0;
        do{assert(used<sizeof(line)-1);assert(read(tcp,line+used,1)==1);}while(line[used++]!='\n');
        line[used]=0;json_object *o=json_tokener_parse(line);assert(o);
        const char *type=string(o,"type");
        if(type&&!strcmp(type,"transport")){
            const char *encoded=string(o,"key");unsigned char decoded[33];assert(encoded&&strlen(encoded)==44);
            assert(EVP_DecodeBlock(decoded,(const unsigned char*)encoded,44)==33);memcpy(key,decoded,32);
            json_object *port=NULL;assert(json_object_object_get_ex(o,"port",&port));
            *peer=(struct sockaddr_in){.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK),.sin_port=htons((uint16_t)json_object_get_int(port))};
            json_object_put(o);return;
        }
        json_object_put(o);
    }
}
static void wait_connected(int tcp){
    char line[512];
    for(;;){
        size_t used=0;
        do{assert(used<sizeof(line)-1);assert(read(tcp,line+used,1)==1);}while(line[used++]!='\n');
        line[used]=0;json_object *o=json_tokener_parse(line);assert(o);
        const char *state=string(o,"state");int connected=state&&!strcmp(state,"connected");
        json_object_put(o);if(connected)return;
    }
}
static void send_input(int fd,const struct sockaddr_in *peer,const unsigned char key[32],uint64_t sequence,uint32_t buttons){
    uint8_t packet[VGF_PACKET_SIZE]={0};
    for(int i=7;i>=0;i--){packet[i]=(uint8_t)sequence;sequence>>=8;}
    memcpy(packet+8,"VGF2",4);for(int i=0;i<4;i++)packet[12+i]=(uint8_t)(buttons>>(8*i));
    unsigned len=0;assert(HMAC(EVP_sha256(),key,32,packet,24,packet+24,&len)&&len==32);
    assert(sendto(fd,packet,sizeof(packet),0,(const struct sockaddr*)peer,sizeof(*peer))==sizeof(packet));
}
static void usb_session_survives_stall(void){
    int hid[2],tcp[2];socket_hid(hid);unsigned filled=fill_hid(hid[0]);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);test_tcp=tcp[0];test_hid=hid[0];
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);assert(rfkill_blocked==1);_exit(0);
    }
    close(hid[0]);close(tcp[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    /* The old USB 100ms cutoff exits while the host still holds its last report. */
    usleep(160000);assert(waitpid(child,NULL,WNOHANG)==0);
    int udp=socket(AF_INET,SOCK_DGRAM,0);assert(udp>=0);
    const uint32_t buttons[]={1u<<A,(1u<<A)|(1u<<B),1u<<B,0};
    for(unsigned i=0;i<4;i++)send_input(udp,&peer,key,i+1,buttons[i]);
    usleep(10000);
    /* Queued edges are still waiting for the host: no ack yet. */
    struct pollfd u={udp,POLLIN,0};assert(poll(&u,1,0)==0);
    uint8_t report[8];for(unsigned i=0;i<filled;i++){assert(read(hid[1],report,8)==8);assert(report[0]==0xaa);}
    unsigned edge=0;double deadline=now_s()+1;
    while(edge<4&&now_s()<deadline){
        struct pollfd p={hid[1],POLLIN,0};if(poll(&p,1,100)<=0)continue;
        assert(read(hid[1],report,8)==8);
        if(!edge&&!report[0]&&!report[1])continue; /* Pending initial neutral. */
        vgf_input expected={.buttons=buttons[edge]};uint8_t bytes[8];vgf_usb_report(&expected,bytes);
        assert(!memcmp(report,bytes,8));edge++;
    }
    assert(edge==4);
    /* After all four edges reach HID, exactly one authenticated ack names the newest sequence. */
    assert(poll(&u,1,1000)==1);uint8_t ack[64],expected[VGF_ACK_SIZE];
    assert(recv(udp,ack,sizeof(ack),0)==VGF_ACK_SIZE);vgf_ack(key,4,expected);assert(!memcmp(ack,expected,VGF_ACK_SIZE));
    assert(poll(&u,1,100)==0);
    close(tcp[1]);wait_child(child);close(udp);close(hid[1]);
}
static void usb_report_precedes_ack(void){
    int hid[2],tcp[2];socket_hid(hid);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    vgf_input x={.buttons=1u<<X};vgf_usb_report(&x,watched);
    /* Cable control owns the uart (U held): the TLS session falls back to UDP only. */
    int owner=open(test_serial_lock,O_RDWR);assert(owner>=0&&flock(owner,LOCK_EX|LOCK_NB)==0);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);test_tcp=tcp[0];test_hid=hid[0];
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);assert(hid_at&&ack_at&&hid_at<ack_at);_exit(0);
    }
    close(hid[0]);close(tcp[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    int udp=socket(AF_INET,SOCK_DGRAM,0);assert(udp>=0);send_input(udp,&peer,key,1,1u<<X);
    int acked=0;double deadline=now_s()+1;uint8_t buf[64];
    while(!acked&&now_s()<deadline){
        struct pollfd p[2]={{hid[1],POLLIN,0},{udp,POLLIN,0}};if(poll(p,2,100)<=0)continue;
        if(p[0].revents&POLLIN)assert(read(hid[1],buf,8)==8);
        if(p[1].revents&POLLIN){assert(recv(udp,buf,sizeof(buf),0)==VGF_ACK_SIZE);acked=1;}
    }
    assert(acked);close(tcp[1]);wait_child(child);close(udp);close(hid[1]);close(owner);
}
static void serial_session_precedes_ack_and_rejects_old_udp(void){
    int hid[2],tcp[2],wire[2];socket_hid(hid);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,wire)==0);assert(set_nonblocking(wire[0])==0);
    vgf_input a={.buttons=1u<<A};vgf_usb_report(&a,watched);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);close(wire[1]);test_tcp=tcp[0];test_hid=hid[0];test_serial=wire[0];
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);assert(hid_at&&serial_at&&hid_at<serial_at);_exit(0);
    }
    close(hid[0]);close(tcp[0]);close(wire[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    /* The TLS session took U before announcing its transport. */
    int u=open(test_serial_lock,O_RDWR);assert(u>=0&&flock(u,LOCK_EX|LOCK_NB)<0&&errno==EWOULDBLOCK);close(u);
    uint8_t frame[VGF_SERIAL_INPUT];vgf_serial_frame(2,&a,frame);assert(write(wire[1],frame,sizeof(frame))==sizeof(frame));
    uint8_t ack[VGF_SERIAL_ACK],expected[VGF_SERIAL_ACK];vgf_serial_ack(2,expected);
    assert(read(wire[1],ack,sizeof(ack))==sizeof(ack));assert(!memcmp(ack,expected,sizeof(ack)));
    int udp=socket(AF_INET,SOCK_DGRAM,0);assert(udp>=0);
    send_input(udp,&peer,key,1,1u<<B);struct pollfd p={udp,POLLIN,0};assert(poll(&p,1,50)==0);
    send_input(udp,&peer,key,4,1u<<B);
    int got_ack=0;double deadline=now_s()+1;uint8_t udp_ack[VGF_ACK_SIZE],udp_expected[VGF_ACK_SIZE];
    while(!got_ack&&now_s()<deadline){
        struct pollfd ready[2]={{hid[1],POLLIN,0},{udp,POLLIN,0}};
        if(poll(ready,2,100)<=0)continue;
        if(ready[0].revents&POLLIN){uint8_t report[8];assert(read(hid[1],report,sizeof(report))==sizeof(report));}
        if(ready[1].revents&POLLIN){assert(recv(udp,udp_ack,sizeof(udp_ack),0)==VGF_ACK_SIZE);got_ack=1;}
    }
    assert(got_ack);vgf_ack(key,4,udp_expected);
    assert(!memcmp(udp_ack,udp_expected,sizeof(udp_ack)));
    /* UDP 4 arrived first; late serial 3 gets a health ack but no replay. */
    vgf_serial_frame(3,&a,frame);assert(write(wire[1],frame,sizeof(frame))==sizeof(frame));
    vgf_serial_ack(3,expected);assert(read(wire[1],ack,sizeof(ack))==sizeof(ack));
    assert(!memcmp(ack,expected,sizeof(ack)));
    close(tcp[1]);wait_child(child);close(udp);close(wire[1]);close(hid[1]);
}
static void usb_cleanup_releases_after_resume(void){
    int hid[2],ready[2];socket_hid(hid);unsigned filled=fill_hid(hid[0]);assert(pipe(ready)==0);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(3);close(hid[0]);close(ready[0]);assert(write(ready[1],"r",1)==1);close(ready[1]);
        /* Resume promptly so a busy single-core installer has scheduling margin.
           The permanently blocked case below checks both bounded wait windows. */
        usleep(5000);uint8_t report[8];
        for(unsigned i=0;i<filled;i++){assert(read(hid[1],report,8)==8);assert(report[0]==0xaa);}
        assert(read(hid[1],report,8)==8);
        const uint8_t neutral[8]={0,0,8,128,128,128,128,0};assert(!memcmp(report,neutral,8));
        close(hid[1]);_exit(0);
    }
    close(hid[1]);close(ready[1]);char signal;assert(read(ready[0],&signal,1)==1);close(ready[0]);
    vgf_protocol protocol={0};hid_release(hid[0],1,&protocol);close(hid[0]);wait_child(child);
}
static void usb_cleanup_is_bounded(void){
    int hid[2];socket_hid(hid);fill_hid(hid[0]);vgf_protocol protocol={0};
    double started=now_s();hid_release(hid[0],1,&protocol);double elapsed=now_s()-started;
    assert(elapsed>=.03&&elapsed<.5);close(hid[0]);close(hid[1]);
}
static void pending_bluetooth_returns_to_usb(void){
    int hid[2],tcp[2];socket_hid(hid);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    usb_ready=mmap(NULL,sizeof(*usb_ready),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);
    assert(usb_ready!=MAP_FAILED);*usb_ready=0;
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(3);close(hid[1]);close(tcp[1]);test_tcp=tcp[0];test_hid=hid[0];
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);_exit(0);
    }
    close(hid[0]);close(tcp[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    assert(waitpid(child,NULL,WNOHANG)==0);
    *usb_ready=1;wait_child(child);
    close(tcp[1]);close(hid[1]);munmap(usb_ready,sizeof(*usb_ready));usb_ready=NULL;
}
static void bluetooth_release_precedes_attach_work(void){
    int hid[2],tcp[2],ready=0;char state[]="/tmp/vgf-attach-XXXXXX";
    assert(mkdtemp(state));assert(socketpair(AF_UNIX,SOCK_SEQPACKET,0,hid)==0);
    assert(set_nonblocking(hid[0])==0);
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(4);close(tcp[1]);test_tcp=tcp[0];test_hid=hid[0];test_hid_peer=hid[1];
        test_bt_connected=1;usb_ready=&ready;root=state;
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);_exit(0);
    }
    close(tcp[0]);close(hid[0]);unsigned char key[32];struct sockaddr_in peer;
    read_transport(tcp[1],key,&peer);wait_connected(tcp[1]);
    int udp=socket(AF_INET,SOCK_DGRAM,0);assert(udp>=0);send_input(udp,&peer,key,1,1u<<A);
    uint8_t report[50];int held=0;double deadline=now_s()+1;
    while(!held&&now_s()<deadline){
        struct pollfd p={hid[1],POLLIN,0};if(poll(&p,1,50)<=0)continue;
        assert(read(hid[1],report,sizeof(report))==sizeof(report));held=(report[4]&(1u<<3))!=0;
    }
    assert(held);
    const char command[]="{\"type\":\"usb\",\"action\":\"attach\"}\n";
    assert(write(tcp[1],command,sizeof(command)-1)==(ssize_t)(sizeof(command)-1));
    wait_child(child);close(tcp[1]);close(hid[1]);close(udp);
    char console[256];snprintf(console,sizeof(console),"%s/console",state);unlink(console);assert(rmdir(state)==0);
}
/* ---- Cable control (serial session, supervisor, TLS takeover) ---- */
static const uint8_t test_id[16]={0x11,0x11,0x11,0x11,0x22,0x22,0x33,0x33,0x44,0x44,0x55,0x55,0x55,0x55,0x55,0x55};
static uint8_t last_hid[8];
static void drain_hid(int hid){
    for(;;){
        struct pollfd p={hid,POLLIN,0};if(poll(&p,1,0)!=1||!(p.revents&POLLIN))return;
        uint8_t r[64];ssize_t n=read(hid,r,sizeof(r));if(n<=0)return;if(n==8)memcpy(last_hid,r,8);
    }
}
static void mac_send(int fd,uint8_t type,const uint8_t body[VGF_SERIAL_BODY]){uint8_t f[VGF_SERIAL_CONTROL];vgf_serial_control_frame(type,body,f);assert(write(fd,f,sizeof(f))==sizeof(f));}
static void mac_hello(int fd,uint8_t version,uint32_t nonce){uint8_t b[VGF_SERIAL_BODY]={version};put32(b+1,nonce);mac_send(fd,VGF_SERIAL_HELLO,b);}
static void mac_usb(int fd,uint32_t id,uint8_t action){uint8_t b[VGF_SERIAL_BODY]={0};put32(b,id);b[4]=action;mac_send(fd,VGF_SERIAL_USB,b);}
static void mac_bye(int fd,uint32_t nonce){uint8_t b[VGF_SERIAL_BODY]={0};put32(b,nonce);mac_send(fd,VGF_SERIAL_BYE,b);}
static void mac_input(int fd,uint64_t seq,const vgf_input *v){uint8_t f[VGF_SERIAL_INPUT];vgf_serial_frame(seq,v,f);assert(write(fd,f,sizeof(f))==sizeof(f));}
/* Next Pi->Mac frame while draining HID: its TYPE, 0 for an ack (*ack = sequence), -1 on timeout/EOF. */
static int pi_frame(int fd,int hid,uint8_t body[VGF_SERIAL_BODY],uint64_t *ack,double timeout){
    uint8_t f[VGF_SERIAL_MAX];size_t used=0,need=0;double deadline=now_s()+timeout;
    while(now_s()<deadline){
        struct pollfd p[2]={{fd,POLLIN,0},{hid,POLLIN,0}};
        if(poll(p,hid>=0?2:1,5)<=0)continue;
        if(hid>=0&&(p[1].revents&POLLIN))drain_hid(hid);else if(hid>=0&&p[1].revents)hid=-1;
        if(!(p[0].revents&(POLLIN|POLLHUP)))continue;
        uint8_t b;if(read(fd,&b,1)!=1)return -1;
        if(!used){if(b==0xa5)f[used++]=b;continue;}
        if(used==1){if(b==0x5a)f[used++]=b;else used=b==0xa5;continue;}
        f[used++]=b;
        if(used==3){assert(b==8||b==VGF_SERIAL_CONTROL_LEN);need=b==8?VGF_SERIAL_ACK:VGF_SERIAL_CONTROL;continue;}
        if(used<need)continue;
        uint16_t crc=vgf_serial_crc(f+2,need-4);assert(f[need-2]==(uint8_t)crc&&f[need-1]==(uint8_t)(crc>>8));
        if(need==VGF_SERIAL_ACK){uint64_t s=0;for(int i=3;i<11;i++)s=s<<8|f[i];if(ack)*ack=s;return 0;}
        memcpy(body,f+4,VGF_SERIAL_BODY);return f[3];
    }
    return -1;
}
/* Skips other frames until `want`; a Pi BYE is never skipped silently. */
static int expect(int fd,int hid,int want,uint8_t body[VGF_SERIAL_BODY],double timeout){
    double deadline=now_s()+timeout;uint64_t ack;
    for(;;){double left=deadline-now_s();if(left<=0)return 0;int t=pi_frame(fd,hid,body,&ack,left);if(t<0)return 0;if(t==want)return 1;assert(t!=VGF_SERIAL_PI_BYE);}
}
static int expect_ack(int fd,int hid,uint64_t seq,double timeout){
    double deadline=now_s()+timeout;uint8_t body[VGF_SERIAL_BODY];uint64_t ack=0;
    for(;;){double left=deadline-now_s();if(left<=0)return 0;int t=pi_frame(fd,hid,body,&ack,left);if(t<0)return 0;assert(t!=VGF_SERIAL_PI_BYE);if(!t&&ack==seq)return 1;}
}
static void serial_wire(int wire[2]){assert(socketpair(AF_UNIX,SOCK_STREAM,0,wire)==0);assert(set_nonblocking(wire[0])==0);}
/* (a) HELLO_REPLY, STATUS, HID-before-ack, idempotent detach, attach ends with BYE(1). */
static void serial_control_session_flow(void){
    int hid[2],wire[2];socket_hid(hid);serial_wire(wire);
    vgf_input a={.buttons=1u<<A};vgf_usb_report(&a,watched);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(wire[1]);test_hid=hid[0];test_serial_fd=wire[0];usb_command_record=1;
        session(NULL,-1,0,wire[0],0x01020304,test_id);
        assert(hid_at&&serial_at&&hid_at<serial_at);assert(detach_count==1&&attach_count==1);_exit(0);
    }
    close(hid[0]);close(wire[0]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack=0;
    assert(pi_frame(wire[1],hid[1],b,&ack,1)==VGF_SERIAL_HELLO_REPLY);
    assert(b[0]==VGF_SERIAL_VERSION&&b[1]==VGF_SERIAL_HELLO_OK&&get32(b+2)==0x01020304&&!memcmp(b+6,test_id,16));
    assert(pi_frame(wire[1],hid[1],b,&ack,1)==VGF_SERIAL_STATUS&&b[0]==VGF_SERIAL_STARTING&&b[1]==VGF_SERIAL_BACKEND_NONE&&!b[2]);
    assert(expect(wire[1],hid[1],VGF_SERIAL_STATUS,b,1)&&b[0]==VGF_SERIAL_CONNECTED&&b[1]==VGF_SERIAL_BACKEND_USB);
    mac_input(wire[1],1,&a);assert(expect_ack(wire[1],hid[1],1,1));
    mac_usb(wire[1],1,VGF_SERIAL_USB_DETACH);mac_usb(wire[1],1,VGF_SERIAL_USB_DETACH);
    unsigned results=0;int detached=0;double deadline=now_s()+1;
    while((results<2||!detached)&&now_s()<deadline){
        int t=pi_frame(wire[1],hid[1],b,&ack,deadline-now_s());if(t<0)break;assert(t!=VGF_SERIAL_PI_BYE);
        if(t==VGF_SERIAL_USB_RESULT){assert(get32(b)==1&&b[4]==VGF_SERIAL_USB_ACCEPTED);results++;}
        if(t==VGF_SERIAL_STATUS&&b[0]==VGF_SERIAL_DETACHED)detached=1;
    }
    assert(results==2&&detached);
    mac_usb(wire[1],2,VGF_SERIAL_USB_ATTACH);
    assert(expect(wire[1],hid[1],VGF_SERIAL_USB_RESULT,b,1)&&get32(b)==2&&b[4]==VGF_SERIAL_USB_ACCEPTED);
    assert(expect(wire[1],hid[1],VGF_SERIAL_PI_BYE,b,1)&&get32(b)==0x01020304&&b[4]==VGF_SERIAL_BYE_ATTACH);
    wait_child(child);close(wire[1]);close(hid[1]);
}
/* (b) A held controller lock answers HELLO_REPLY busy and starts nothing. */
static void serial_control_busy(void){
    int wire[2],err[2];serial_wire(wire);assert(pipe(err)==0);int held=open(test_lock,O_RDWR);assert(held>=0&&flock(held,LOCK_EX)==0);
    pid_t child=fork();assert(child>=0);
    if(!child){alarm(3);close(wire[1]);close(held);close(err[0]);dup2(err[1],2);close(err[1]);session(NULL,-1,0,wire[0],5,test_id);_exit(0);}
    close(wire[0]);close(err[1]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack;
    assert(pi_frame(wire[1],-1,b,&ack,1)==VGF_SERIAL_HELLO_REPLY&&b[1]==VGF_SERIAL_HELLO_BUSY&&get32(b+2)==5);
    wait_child(child);assert(pi_frame(wire[1],-1,b,&ack,.1)<0);close(held);close(wire[1]);
    /* No session started, so no session end line. */
    char log[4096];size_t used=0;ssize_t n;
    while(used<sizeof log-1&&(n=read(err[0],log+used,sizeof log-1-used))>0)used+=(size_t)n;
    log[used]=0;close(err[0]);assert(!strstr(log,"session end"));
}
/* (c) No Mac frame for the peer timeout ends with BYE(2). */
static void serial_control_peer_timeout(void){
    int hid[2],wire[2];socket_hid(hid);serial_wire(wire);
    pid_t child=fork();assert(child>=0);
    if(!child){alarm(3);close(hid[1]);close(wire[1]);test_hid=hid[0];serial_peer_timeout=.3;session(NULL,-1,0,wire[0],6,test_id);_exit(0);}
    close(hid[0]);close(wire[0]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack;
    assert(pi_frame(wire[1],hid[1],b,&ack,1)==VGF_SERIAL_HELLO_REPLY);double started=now_s();
    assert(expect(wire[1],hid[1],VGF_SERIAL_PI_BYE,b,2)&&get32(b)==6&&b[4]==VGF_SERIAL_BYE_PEER_TIMEOUT);
    double elapsed=now_s()-started;assert(elapsed>=.25&&elapsed<1.5);
    wait_child(child);close(wire[1]);close(hid[1]);
}
/* (d) Only the session's nonce ends it. */
static void serial_control_bye_nonce(void){
    int hid[2],wire[2];socket_hid(hid);serial_wire(wire);
    pid_t child=fork();assert(child>=0);
    if(!child){alarm(3);close(hid[1]);close(wire[1]);test_hid=hid[0];session(NULL,-1,0,wire[0],7,test_id);_exit(0);}
    close(hid[0]);close(wire[0]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack;
    assert(pi_frame(wire[1],hid[1],b,&ack,1)==VGF_SERIAL_HELLO_REPLY);
    mac_bye(wire[1],8);double until=now_s()+.2;
    while(now_s()<until){int t=pi_frame(wire[1],hid[1],b,&ack,until-now_s());if(t<0)break;assert(t!=VGF_SERIAL_PI_BYE);}
    assert(waitpid(child,NULL,WNOHANG)==0);
    mac_bye(wire[1],7);assert(expect(wire[1],hid[1],VGF_SERIAL_PI_BYE,b,1)&&get32(b)==7&&b[4]==VGF_SERIAL_BYE_ENDED);
    wait_child(child);close(wire[1]);close(hid[1]);
}
/* (e) Same-nonce HELLO is re-answered; a new nonce replaces the session with BYE(3). */
static void serial_control_hello_replay(void){
    int hid[2],wire[2];socket_hid(hid);serial_wire(wire);
    pid_t child=fork();assert(child>=0);
    if(!child){alarm(3);close(hid[1]);close(wire[1]);test_hid=hid[0];session(NULL,-1,0,wire[0],9,test_id);_exit(0);}
    close(hid[0]);close(wire[0]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack;
    assert(pi_frame(wire[1],hid[1],b,&ack,1)==VGF_SERIAL_HELLO_REPLY);
    mac_hello(wire[1],VGF_SERIAL_VERSION,9);
    assert(expect(wire[1],hid[1],VGF_SERIAL_HELLO_REPLY,b,1)&&b[1]==VGF_SERIAL_HELLO_OK&&get32(b+2)==9&&!memcmp(b+6,test_id,16));
    mac_hello(wire[1],VGF_SERIAL_VERSION,10);
    assert(expect(wire[1],hid[1],VGF_SERIAL_PI_BYE,b,1)&&get32(b)==9&&b[4]==VGF_SERIAL_BYE_REPLACED);
    wait_child(child);close(wire[1]);close(hid[1]);
}
/* (f) A cable HELLO during a TLS session ends it, releasing HID to neutral. */
static void tls_session_yields_to_serial_hello(void){
    int hid[2],tcp[2],wire[2];socket_hid(hid);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);serial_wire(wire);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);close(wire[1]);test_tcp=tcp[0];test_hid=hid[0];test_serial=wire[0];
        session(NULL,tcp[0],0,-1,0,NULL);close(tcp[0]);_exit(0);
    }
    close(hid[0]);close(tcp[0]);close(wire[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    vgf_input a={.buttons=1u<<A};uint8_t held[8];vgf_usb_report(&a,held);
    mac_input(wire[1],1,&a);assert(expect_ack(wire[1],hid[1],1,1));drain_hid(hid[1]);assert(!memcmp(last_hid,held,8));
    mac_hello(wire[1],VGF_SERIAL_VERSION,11);
    int status=0;pid_t ended=0;double deadline=now_s()+1;
    while(!(ended=waitpid(child,&status,WNOHANG))&&now_s()<deadline){struct pollfd p={hid[1],POLLIN,0};if(poll(&p,1,10)>0)drain_hid(hid[1]);}
    assert(ended==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0);
    drain_hid(hid[1]);const uint8_t neutral[8]={0,0,8,128,128,128,128,0};assert(!memcmp(last_hid,neutral,8));
    close(tcp[1]);close(wire[1]);close(hid[1]);
}
static int serial_lock_held_elsewhere(void){
    int u=open(test_serial_lock,O_RDWR);assert(u>=0);int held=flock(u,LOCK_EX|LOCK_NB)<0;assert(!held||errno==EWOULDBLOCK);close(u);return held;
}
/* (h) Supervisor: answers HELLO, ignores idle input/USB/BYE, yields U to a TLS session, takes it back, stops on SIGTERM. */
static void serial_supervisor_hands_off(void){
    char state[]="/tmp/vgf-supervisor-XXXXXX";assert(mkdtemp(state));
    int wire[2];serial_wire(wire);
    pid_t child=fork();assert(child>=0);
    if(!child){alarm(5);close(wire[1]);root=state;test_serial=wire[0];serial_supervisor();_exit(0);}
    close(wire[0]);uint8_t b[VGF_SERIAL_BODY];uint64_t ack;
    double started=now_s();while(!serial_lock_held_elsewhere()){assert(now_s()-started<1);usleep(5000);}
    mac_hello(wire[1],VGF_SERIAL_VERSION,0x21);
    assert(pi_frame(wire[1],-1,b,&ack,1)==VGF_SERIAL_HELLO_REPLY&&b[1]==VGF_SERIAL_HELLO_UNREGISTERED&&get32(b+2)==0x21);
    char path[512];snprintf(path,sizeof(path),"%s/device.json",state);FILE *f=fopen(path,"w");assert(f);
    fputs("{\"id\":\"11111111-2222-3333-4444-555555555555\"}",f);assert(fclose(f)==0);
    mac_hello(wire[1],VGF_SERIAL_VERSION+1,0x22);
    assert(pi_frame(wire[1],-1,b,&ack,1)==VGF_SERIAL_HELLO_REPLY&&b[1]==VGF_SERIAL_HELLO_VERSION&&get32(b+2)==0x22&&!memcmp(b+6,test_id,16));
    vgf_input a={.buttons=1u<<A};mac_input(wire[1],1,&a);mac_usb(wire[1],1,VGF_SERIAL_USB_ATTACH);mac_bye(wire[1],0x22);
    assert(pi_frame(wire[1],-1,b,&ack,.15)<0);
    /* A TLS session takes S: U is free within 200ms. */
    int s=open(test_lock,O_RDWR);assert(s>=0&&flock(s,LOCK_EX)==0);
    int u=open(test_serial_lock,O_RDWR);assert(u>=0);started=now_s();
    while(flock(u,LOCK_EX|LOCK_NB)<0){assert(errno==EWOULDBLOCK&&now_s()-started<.2);usleep(2000);}
    /* That session ends (U, then S): the supervisor holds U again within 200ms and answers. */
    close(u);close(s);started=now_s();
    while(!serial_lock_held_elsewhere()){assert(now_s()-started<.2);usleep(2000);}
    mac_hello(wire[1],VGF_SERIAL_VERSION+1,0x23);
    assert(pi_frame(wire[1],-1,b,&ack,1)==VGF_SERIAL_HELLO_REPLY&&b[1]==VGF_SERIAL_HELLO_VERSION&&get32(b+2)==0x23);
    assert(kill(child,SIGTERM)==0);wait_child(child);
    close(wire[1]);assert(unlink(path)==0);assert(rmdir(state)==0);
}
int main(void){
    signal(SIGPIPE,SIG_IGN);alarm(30);int lock=mkstemp(test_lock);assert(lock>=0);close(lock);lock=mkstemp(test_serial_lock);assert(lock>=0);close(lock);
    usb_session_survives_stall();usb_report_precedes_ack();serial_session_precedes_ack_and_rejects_old_udp();usb_cleanup_releases_after_resume();usb_cleanup_is_bounded();pending_bluetooth_returns_to_usb();bluetooth_release_precedes_attach_work();
    serial_control_session_flow();serial_control_busy();serial_control_peer_timeout();serial_control_bye_nonce();serial_control_hello_replay();tls_session_yields_to_serial_hello();serial_supervisor_hands_off();
    assert(unlink(test_lock)==0);assert(unlink(test_serial_lock)==0);
    puts("PASS USB session survives backpressure, ordered HID/acks, UDP-only when cable control owns the uart, neutral cleanup, pending Bluetooth returns to USB, Bluetooth releases before attach helper");
    puts("PASS serial control session flow, busy, peer timeout, BYE nonce, HELLO replay/replace, TLS takeover, supervisor hand-off");return 0;
}
