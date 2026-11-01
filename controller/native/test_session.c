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

static int test_tcp=-1,test_hid=-1,test_hid_peer=-1,test_serial=-1,test_bt_connected=0;
static double now_s(void);
static int *usb_ready;
static char test_lock[]="/tmp/vgf-session-XXXXXX";
static int isolated_open(const char *path,int flags,...){
    mode_t mode=0;
    if(flags&O_CREAT){va_list ap;va_start(ap,flags);mode=va_arg(ap,int);va_end(ap);}
    if(!strcmp(path,"/run/videogamefilter-controller.lock"))path=test_lock;
    return open(path,flags,mode);
}
static int socket_usb_open(void){return (!usb_ready||*usb_ready)?test_hid:-1;}
static int socket_serial_open(const char *path){(void)path;return test_serial;}
static int socket_usb_configured(void){return !usb_ready||*usb_ready;}
static int waiting_bt_setup(vgf_bt *b,const char *sdp){(void)sdp;b->ctrl=b->itr=b->listen_ctrl=b->listen_itr=-1;b->bus=NULL;return 0;}
static int waiting_bt_connect(vgf_bt *b,const char *address){(void)b;(void)address;return -1;}
static int waiting_bt_listen(vgf_bt *b){(void)b;return 0;}
static int waiting_bt_accept(vgf_bt *b){if(!test_bt_connected)return 0;b->itr=test_hid;return 1;}
static void waiting_bt_close(vgf_bt *b){(void)b;}
static int checked_usb_command(const char *action){
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
static ssize_t ordered_write(int fd,const void *b,size_t n){ssize_t r=write(fd,b,n);if(fd==test_hid&&r==8&&!memcmp(b,watched,8)&&!hid_at)hid_at=++order;if(fd==test_serial&&r==VGF_SERIAL_ACK&&!serial_at)serial_at=++order;return r;}
static ssize_t ordered_sendto(int fd,const void *b,size_t n,int f,const struct sockaddr *a,socklen_t l){ssize_t r=sendto(fd,b,n,f,a,l);if(r==VGF_ACK_SIZE&&!ack_at)ack_at=++order;return r;}
static int plain_write(SSL *ssl,const void *data,int n){(void)ssl;return (int)send(test_tcp,data,(size_t)n,MSG_NOSIGNAL);}
static int plain_read(SSL *ssl,void *data,int n){(void)ssl;return (int)recv(test_tcp,data,(size_t)n,0);}
static int plain_pending(const SSL *ssl){(void)ssl;return 0;}
static int plain_error(const SSL *ssl,int n){(void)ssl;return n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)?SSL_ERROR_WANT_READ:SSL_ERROR_ZERO_RETURN;}

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
        session(NULL,tcp[0],0);close(tcp[0]);assert(rfkill_blocked==1);_exit(0);
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
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);test_tcp=tcp[0];test_hid=hid[0];
        session(NULL,tcp[0],0);close(tcp[0]);assert(hid_at&&ack_at&&hid_at<ack_at);_exit(0);
    }
    close(hid[0]);close(tcp[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
    int udp=socket(AF_INET,SOCK_DGRAM,0);assert(udp>=0);send_input(udp,&peer,key,1,1u<<X);
    int acked=0;double deadline=now_s()+1;uint8_t buf[64];
    while(!acked&&now_s()<deadline){
        struct pollfd p[2]={{hid[1],POLLIN,0},{udp,POLLIN,0}};if(poll(p,2,100)<=0)continue;
        if(p[0].revents&POLLIN)assert(read(hid[1],buf,8)==8);
        if(p[1].revents&POLLIN){assert(recv(udp,buf,sizeof(buf),0)==VGF_ACK_SIZE);acked=1;}
    }
    assert(acked);close(tcp[1]);wait_child(child);close(udp);close(hid[1]);
}
static void serial_session_precedes_ack_and_rejects_old_udp(void){
    int hid[2],tcp[2],wire[2];socket_hid(hid);assert(socketpair(AF_UNIX,SOCK_STREAM,0,tcp)==0);
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,wire)==0);assert(set_nonblocking(wire[0])==0);
    vgf_input a={.buttons=1u<<A};vgf_usb_report(&a,watched);
    pid_t child=fork();assert(child>=0);
    if(!child){
        alarm(5);close(hid[1]);close(tcp[1]);close(wire[1]);test_tcp=tcp[0];test_hid=hid[0];test_serial=wire[0];
        session(NULL,tcp[0],0);close(tcp[0]);assert(hid_at&&serial_at&&hid_at<serial_at);_exit(0);
    }
    close(hid[0]);close(tcp[0]);close(wire[0]);unsigned char key[32];struct sockaddr_in peer;read_transport(tcp[1],key,&peer);
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
        session(NULL,tcp[0],0);close(tcp[0]);_exit(0);
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
        session(NULL,tcp[0],0);close(tcp[0]);_exit(0);
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
int main(void){
    signal(SIGPIPE,SIG_IGN);alarm(10);int lock=mkstemp(test_lock);assert(lock>=0);close(lock);
    usb_session_survives_stall();usb_report_precedes_ack();serial_session_precedes_ack_and_rejects_old_udp();usb_cleanup_releases_after_resume();usb_cleanup_is_bounded();pending_bluetooth_returns_to_usb();bluetooth_release_precedes_attach_work();
    assert(unlink(test_lock)==0);puts("PASS USB session survives backpressure, ordered HID/acks, neutral cleanup, pending Bluetooth returns to USB, Bluetooth releases before attach helper");return 0;
}
