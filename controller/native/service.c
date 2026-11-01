/* SPDX-License-Identifier: MIT -- Native VGF TLS control + UDP/Bluetooth input daemon. */
#include "protocol.h"
#include "bluetooth.h"
#include "usb.h"
#include "serial.h"
#include <openssl/ssl.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <json-c/json.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <math.h>

static volatile sig_atomic_t stopping;
static const char *root="/var/lib/videogamefilter-controller";
static const char *sdp="/opt/videogamefilter-controller/native/switch-controller.xml";
static double *failures;
static double now_s(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void stop(int sig){(void)sig;stopping=1;}
static void path_for(char out[512],const char *name){snprintf(out,512,"%s/%s",root,name);}
static const char *string(json_object *o,const char *k){json_object *v=NULL;if(!o||!json_object_object_get_ex(o,k,&v)||!json_object_is_type(v,json_type_string))return NULL;return json_object_get_string(v);}
static int truth(json_object *o,const char *k){json_object *v=NULL;return o&&json_object_object_get_ex(o,k,&v)&&json_object_is_type(v,json_type_boolean)&&json_object_get_boolean(v);}
static void hex(const unsigned char *b,size_t n,char *out){for(size_t i=0;i<n;i++)sprintf(out+i*2,"%02x",b[i]);out[n*2]=0;}
static int unhex(const char *s,unsigned char *b,size_t n){if(!s||strlen(s)!=n*2)return -1;for(size_t i=0;i<n;i++){unsigned v=0;for(int j=0;j<2;j++){char c=s[i*2+j];if(c>='0'&&c<='9')v=v*16+c-'0';else if(c>='a'&&c<='f')v=v*16+c-'a'+10;else return -1;}b[i]=(unsigned char)v;}return 0;}
static void digest(const char *s,char out[65]){unsigned char h[32];SHA256((const unsigned char*)s,strlen(s),h);hex(h,32,out);}
static int equal_hash(const char *a,const char *b){return a&&b&&strlen(a)==64&&strlen(b)==64&&CRYPTO_memcmp(a,b,64)==0;}
static int save_registry(json_object *data){
    char path[512],temp[512];path_for(path,"device.json");path_for(temp,"device.json.tmp");
    const char *s=json_object_to_json_string_ext(data,JSON_C_TO_STRING_PLAIN);size_t n=strlen(s),off=0;
    int fd=open(temp,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600);if(fd<0)return -1;
    while(off<n){ssize_t w=write(fd,s+off,n-off);if(w<0&&errno==EINTR)continue;if(w<=0){close(fd);unlink(temp);return -1;}off+=(size_t)w;}
    int r=fsync(fd);if(close(fd)<0)r=-1;if(r||rename(temp,path)<0){unlink(temp);return -1;}
    fd=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(fd<0)return -1;r=fsync(fd);close(fd);return r;
}
/* A per-child open file description makes flock inter-process, including fork siblings. */
static int registry_lock(void){char path[512];path_for(path,"registry.lock");int fd=open(path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600);if(fd>=0&&flock(fd,LOCK_EX)<0){close(fd);return -1;}return fd;}
static int authenticate(json_object *request,char token[65],char client[65]){
    const char *id=string(request,"client");if(!id||strlen(id)<16||strlen(id)>64)return -1;
    for(const unsigned char *p=(const unsigned char*)id;*p;p++)if(!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')||*p=='-'))return -1;
    strcpy(client,id);token[0]=0;int lock=registry_lock();if(lock<0)return -1;
    char path[512];path_for(path,"device.json");json_object *data=json_object_from_file(path),*stored=NULL;int result=-1;
    if(!data)goto done;json_object_object_get_ex(data,"client",&stored);
    const char *oldid=string(stored,"id"),*oldhash=string(stored,"hash"),*provided=string(request,"token");char hash[65];
    if(provided&&strlen(provided)==64&&oldid&&!strcmp(id,oldid)){
        digest(provided,hash);
        if(equal_hash(oldhash,hash)){
            if(!truth(data,"paired")){json_object_object_add(data,"paired",json_object_new_boolean(1));json_object_object_del(data,"pin_hash");if(save_registry(data))goto done;}
            result=0;goto done;
        }
    }
    double now=now_s();unsigned failed=0;for(int i=0;i<5;i++)if(failures[i]>0&&now-failures[i]<60)failed++;
    if(failed>=5)goto done;
    const char *pin=string(request,"pin"),*device=string(data,"id"),*expected=string(data,"pin_hash");
    int valid=pin&&strlen(pin)==6&&device&&strlen(device)<=64&&!truth(data,"paired")&&(!oldid||!strcmp(oldid,id));
    if(valid){for(int i=0;i<6;i++)if(pin[i]<'0'||pin[i]>'9')valid=0;}
    if(valid){char joined[80];snprintf(joined,sizeof(joined),"%s:%s",device,pin);digest(joined,hash);valid=equal_hash(expected,hash);}
    if(!valid){for(int i=0;i<5;i++)if(failures[i]==0||now-failures[i]>=60){failures[i]=now;break;}goto done;}
    unsigned char secret[32],mac[32];unsigned len=0;
    if(unhex(string(data,"secret"),secret,32))goto done;
    if(!HMAC(EVP_sha256(),secret,32,(const unsigned char*)id,strlen(id),mac,&len)||len!=32){OPENSSL_cleanse(secret,32);goto done;}
    OPENSSL_cleanse(secret,32);hex(mac,32,token);digest(token,hash);
    stored=json_object_new_object();json_object_object_add(stored,"id",json_object_new_string(id));json_object_object_add(stored,"hash",json_object_new_string(hash));json_object_object_add(data,"client",stored);
    if(save_registry(data)){OPENSSL_cleanse(token,65);goto done;}result=1;
 done:if(data)json_object_put(data);flock(lock,LOCK_UN);close(lock);return result;
}
static int confirm(const char *client){
    int lock=registry_lock();if(lock<0)return -1;char path[512];path_for(path,"device.json");json_object *d=json_object_from_file(path),*c=NULL;int r=-1;
    if(d){json_object_object_get_ex(d,"client",&c);const char *id=string(c,"id");if(id&&!strcmp(id,client)){json_object_object_add(d,"paired",json_object_new_boolean(1));json_object_object_del(d,"pin_hash");r=save_registry(d);}json_object_put(d);}
    flock(lock,LOCK_UN);close(lock);return r;
}
static json_object *read_json(SSL *ssl){
    char buf[4097];size_t used=0;double deadline=now_s()+10;
    while(used<sizeof(buf)-1&&now_s()<deadline){int n=SSL_read(ssl,buf+used,1);if(n!=1)return NULL;if(buf[used]=='\n'){buf[used]=0;json_tokener *t=json_tokener_new();json_object *o=json_tokener_parse_ex(t,buf,(int)used);int ok=json_tokener_get_error(t)==json_tokener_success&&json_object_is_type(o,json_type_object)&&json_tokener_get_parse_end(t)==used;json_tokener_free(t);if(!ok){if(o)json_object_put(o);return NULL;}return o;}used++;}return NULL;
}
static int send_blocking(SSL *ssl,const char *s){size_t n=strlen(s),off=0;while(off<n){int r=SSL_write(ssl,s+off,(int)(n-off));if(r<=0)return -1;off+=(size_t)r;}return 0;}
static void status_line(char *out,size_t n,const char *state,int usb){snprintf(out,n,"{\"type\":\"status\",\"state\":\"%s\",\"backend\":\"%s\",\"usbState\":\"%s\",\"wake\":false}\n",state,usb?"usb":"bluetooth",vgf_usb_state());}
#ifndef VGF_USB_COMMAND
#define VGF_USB_COMMAND usb_command
static int usb_command(const char *action){
    pid_t pid=fork();if(pid<0)return -1;
    if(pid==0){execl("/opt/videogamefilter-controller/native/usb-control.sh","usb-control.sh",action,(char*)NULL);_exit(127);}
    int status=0;while(waitpid(pid,&status,0)<0){if(errno!=EINTR)return -1;}
    return WIFEXITED(status)&&WEXITSTATUS(status)==0?0:-1;
}
#endif
static int set_nonblocking(int fd){int flags=fcntl(fd,F_GETFL);return flags<0?-1:fcntl(fd,F_SETFL,flags|O_NONBLOCK);}
static int console_address(char out[18]){char path[512];path_for(path,"console");FILE *f=fopen(path,"r");if(!f)return -1;char buf[64];int ok=fgets(buf,sizeof(buf),f)!=NULL;fclose(f);if(!ok)return -1;buf[strcspn(buf,"\r\n")]=0;bdaddr_t a;if(strlen(buf)!=17||str2ba(buf,&a)<0)return -1;strcpy(out,buf);return 0;}
static int save_console(const bdaddr_t *a){char path[512],temp[512],address[18];ba2str(a,address);path_for(path,"console");path_for(temp,"console.tmp");int fd=open(temp,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600);if(fd<0)return -1;int ok=write(fd,address,17)==17&&fsync(fd)==0;close(fd);if(!ok||rename(temp,path)<0){unlink(temp);return -1;}return 0;}

static ssize_t hid_send(int fd,int usb,const uint8_t *data){return usb?write(fd,data,8):send(fd,data,50,MSG_NOSIGNAL);}
static void hid_release(int fd,int usb,vgf_protocol *protocol){
    vgf_input zero={0};uint8_t report[50];
    if(usb)vgf_usb_report(&zero,report);else vgf_report(protocol,&zero,NULL,0,now_s(),report);
    /* Closing a gadget fd does not release the host's last buttons. Give a
       pending USB transfer two bounded opportunities to finish before closing. */
    for(int retry=0;;retry++){
        ssize_t n=hid_send(fd,usb,report);
        if(!usb||n>=0||retry==2||(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR))return;
        struct pollfd p={fd,POLLOUT,0};
        if((poll(&p,1,20)<0&&errno!=EINTR)||(p.revents&(POLLERR|POLLHUP|POLLNVAL)))return;
    }
}
static void session(SSL *ssl,int tcp,int pair){
    int lock=open("/run/videogamefilter-controller.lock",O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600),udp=-1,serial=-1;
    vgf_bt bt={.ctrl=-1,.itr=-1,.listen_ctrl=-1,.listen_itr=-1};vgf_queue queue={0};vgf_protocol protocol={0};unsigned char key[32]={0};
    uint64_t sequence=0,accepted=0,serial_accepted=0,serial_invalid=0,invalid=0,reports=0,blocked=0,udp_gaps=0;double max_gap=0,last_sent=0,max_udp_gap=0,last_udp=0;int connected=0,use_usb=0,listening=0,detached=access("/run/vgf-usb-manual-detach",F_OK)==0;vgf_serial_parser serial_parser={0};uint64_t serial_ack_sequence=0;
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)<0){send_blocking(ssl,"{\"type\":\"error\",\"message\":\"다른 컨트롤러 연결이 사용 중입니다.\"}\n");goto done;}
    if(send_blocking(ssl,"{\"type\":\"status\",\"state\":\"starting\",\"wake\":false}\n"))goto done;
    if(detached){fputs("USB manually detached; waiting for authenticated attach\n",stderr);}
    else if(!pair && (bt.itr=vgf_usb_open())>=0){use_usb=1;connected=1;
        /* USB needs no radio. An idle BT controller still takes coexistence airtime from Wi-Fi. */
        int r=vgf_bt_rfkill(1);if(r<0)fprintf(stderr,"Bluetooth rfkill block failed: %s\n",strerror(errno));else if(r)fputs("Bluetooth radio blocked for USB session\n",stderr);}
    else {
        int unblocked=vgf_bt_rfkill(0);if(unblocked<0)fprintf(stderr,"Bluetooth rfkill unblock failed: %s\n",strerror(errno));
        /* bluetoothd observes the unblock asynchronously; Powered may briefly report Blocked. */
        for(int retry=0;vgf_bt_setup(&bt,sdp);retry++){vgf_bt_close(&bt);
            if(unblocked<=0||retry==4){send_blocking(ssl,"{\"type\":\"error\",\"message\":\"블루투스 초기화 실패\"}\n");goto done;}usleep(250000);}
        char address[18];listening=pair||console_address(address)||vgf_bt_connect(&bt,address);
        if(listening&&vgf_bt_listen(&bt))goto done;
        char own[18];ba2str(&bt.local,own);for(int i=0;i<6;i++){unsigned n=0;sscanf(own+i*3,"%2x",&n);protocol.address[i]=(uint8_t)n;}
    }
    udp=socket(AF_INET,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);if(udp<0)goto done;
    struct sockaddr_in sa={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_ANY)};if(bind(udp,(struct sockaddr*)&sa,sizeof(sa))<0)goto done;
    socklen_t sz=sizeof(sa);if(getsockname(udp,(struct sockaddr*)&sa,&sz)<0||RAND_bytes(key,32)!=1)goto done;
    unsigned char encoded[45];EVP_EncodeBlock(encoded,key,32);char msg[512];snprintf(msg,sizeof(msg),"{\"type\":\"transport\",\"version\":2,\"port\":%u,\"key\":\"%s\"}\n",ntohs(sa.sin_port),encoded);
    if(send_blocking(ssl,msg)||set_nonblocking(tcp)<0)goto done;
    serial=vgf_serial_open("/dev/serial0");if(serial>=0)fputs("serial input ready at 115200\n",stderr);
    double started=now_s(),next_report=started,next_status=started,last_input=started,out_started=0,next_usb_check=0;
    char output[512]={0},control_line[128]={0};size_t output_len=0,output_at=0,control_len=0;int output_want_read=0;
    uint8_t pending_report[50];double report_started=0;int have_report=0;vgf_input current={0};
    uint64_t ack_sequence=0;struct sockaddr_in ack_to;
    while(!stopping){
        double now=now_s();
        if(!connected&&!detached&&!pair&&now>=next_usb_check){
            int fd=vgf_usb_open();
            if(fd>=0){close(fd);break;}
            next_usb_check=now+.25;
        }
        struct pollfd fds[5]={{tcp,POLLIN,0},{udp,POLLIN,0},{bt.ctrl,POLLIN,0},{bt.itr,POLLIN,0},{serial,POLLIN,0}};
        if(output_len&&!output_want_read)fds[0].events|=POLLOUT;
        /* A USB completion wakes POLLOUT immediately. Do not quantize retries
           into another heartbeat; Bluetooth retains its bounded timed retry. */
        if(connected&&have_report)fds[3].events=use_usb?POLLOUT:0;
        if(!connected&&!detached){if(listening){fds[2].fd=bt.listen_ctrl;fds[3].fd=bt.listen_itr;}else{fds[2].events|=POLLOUT;fds[3].events|=POLLOUT;}}

        int wait_ms=(int)ceil((next_report-now)*1000);if(wait_ms<0)wait_ms=0;if(wait_ms>8||!connected||(use_usb&&have_report))wait_ms=8;
        int pr=poll(fds,5,wait_ms);if(pr<0&&errno!=EINTR)break;now=now_s();
        if(fds[0].revents&(POLLERR|POLLHUP|POLLNVAL))break;
        if((fds[0].revents&POLLIN)||SSL_pending(ssl)){
            char incoming[1024];int n=SSL_read(ssl,incoming,sizeof(incoming));if(n<=0){int e=SSL_get_error(ssl,n);if(e!=SSL_ERROR_WANT_READ&&e!=SSL_ERROR_WANT_WRITE)break;}
            else for(int i=0;i<n;i++){
                if(incoming[i]=='\n'){
                    control_line[control_len]=0;
                    json_object *request=json_tokener_parse(control_line);
                    const char *type=string(request,"type"),*action=string(request,"action");
                    if(type&&!strcmp(type,"usb")&&action){
                        if(!strcmp(action,"detach")){
                            if(connected&&bt.itr>=0){hid_release(bt.itr,use_usb,&protocol);vgf_bt_close(&bt);}
                            connected=0;use_usb=0;
                            if(VGF_USB_COMMAND("detach")){fprintf(stderr,"USB detach failed\n");goto done;}
                            detached=1;queue.count=0;have_report=0;current=(vgf_input){0};next_status=0;
                        }else if(!strcmp(action,"attach")){
                            if(connected&&bt.itr>=0){hid_release(bt.itr,use_usb,&protocol);vgf_bt_close(&bt);connected=0;}
                            if(VGF_USB_COMMAND("attach"))fprintf(stderr,"USB attach failed\n");
                            if(request)json_object_put(request);goto done;
                        }
                    }
                    if(request)json_object_put(request);control_len=0;
                }else if(control_len<sizeof(control_line)-1)control_line[control_len++]=incoming[i];
                else control_len=0;
            }
        }
        if(fds[1].revents&POLLIN){
            for(int i=0;i<64;i++){uint8_t data[57];struct sockaddr_in from;socklen_t fromlen=sizeof(from);ssize_t n=recvfrom(udp,data,sizeof(data),0,(struct sockaddr*)&from,&fromlen);if(n<0){if(errno==EAGAIN||errno==EWOULDBLOCK)break;goto done;}
                vgf_input v;if(vgf_decode(data,(size_t)n,key,&sequence,&v)){invalid++;continue;}
                double arrived=now_s();if(last_udp>0){double gap=arrived-last_udp;if(gap>max_udp_gap)max_udp_gap=gap;if(gap>.04)udp_gaps++;}last_udp=arrived;
                vgf_enqueue(&queue,&v,arrived);last_input=arrived;accepted++;
                if(fromlen==sizeof(from)&&from.sin_family==AF_INET){ack_sequence=sequence;ack_to=from;}
                if(use_usb||(protocol.vibration&&protocol.player)){double due=fmax(now,last_sent+(use_usb?.001:.004));if(due<next_report)next_report=due;}
            }
        }
        if(serial>=0 && (fds[4].revents&(POLLERR|POLLHUP|POLLNVAL))){close(serial);serial=-1;fputs("serial input disconnected; UDP remains active\n",stderr);}
        if(serial>=0 && (fds[4].revents&POLLIN)){
            uint8_t bytes[256];ssize_t n=read(serial,bytes,sizeof(bytes));
            if(n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK){close(serial);serial=-1;}
            else for(ssize_t i=0;i<n;i++){
                vgf_input v;uint64_t seq;
                double arrived=now_s();int result=vgf_serial_byte(&serial_parser,bytes[i],&v,&seq);
                if(result<0){serial_invalid++;continue;}if(!result)continue;
                /* The serial parser already checks its own increasing sequence.
                   A Wi-Fi copy can arrive first; acknowledge that older serial
                   frame after HID delivery without replaying its stale state. */
                serial_ack_sequence=seq;if(seq<=sequence)continue;
                sequence=seq;vgf_enqueue(&queue,&v,arrived);last_input=arrived;accepted++;serial_accepted++;
                if(use_usb||(protocol.vibration&&protocol.player)){double due=fmax(arrived,last_sent+(use_usb?.001:.004));if(due<next_report)next_report=due;}
            }
        }
        if(!connected&&!detached){
            int ready=listening?vgf_bt_accept(&bt):vgf_bt_ready(&bt);
            if(ready<0 || (!listening&&now-started>8)){
                if(listening||vgf_bt_listen(&bt))break;listening=1;started=now;
            }else if(ready>0){connected=1;next_report=now;last_input=now;next_status=now;
                if(save_console(&bt.remote))break;
            }
            if(now-started>120)break;
        }
        if(connected){
            now=now_s(); /* The UDP drain may have passed the report deadline. */
            if(now>=next_usb_check){
                if(use_usb && !vgf_usb_configured())break;
                if(!use_usb && !pair && vgf_usb_configured())break; /* Return to USB after watchdog recovery. */
                next_usb_check=now+.25;
            }
            if((fds[2].revents|fds[3].revents)&(POLLERR|POLLHUP|POLLNVAL))break;
            if(fds[2].revents&POLLIN){uint8_t control[64];ssize_t n=recv(bt.ctrl,control,sizeof(control),0);if(n==0)break;/* HID control channel has no application input payload. */}
            /* Disconnecting releases Bluetooth input. USB must retain its pending
               report and queue until the host resumes; closing its fd cannot release it. */
            if(!use_usb && have_report && now-report_started>.1){fprintf(stderr,"Bluetooth HID stalled for 100ms; reconnecting\n");break;}
            /* Send a pending reply before consuming another Switch subcommand/input edge. */
            if(have_report && (use_usb?(fds[3].revents&POLLOUT):now>=next_report)){ssize_t n=hid_send(bt.itr,use_usb,pending_report);if(n==(use_usb?8:50)){have_report=0;reports++;if(last_sent>0&&now-last_sent>max_gap)max_gap=now-last_sent;last_sent=now;next_report=now+((queue.count&&(use_usb||(protocol.vibration&&protocol.player)))?(use_usb?.001:.004):vgf_report_interval(&protocol,use_usb));}else if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){blocked++;next_report=now+.008;}else break;}
            if(!have_report && ((fds[3].revents&POLLIN)||now>=next_report)){
                uint8_t in[128];ssize_t n=use_usb?read(bt.itr,in,sizeof(in)):recv(bt.itr,in,sizeof(in),0);if(n==0)break;if(n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK)break;
                int subcommand=n>=12&&in[0]==0xa2&&in[1]==1;
                if(use_usb||subcommand||now>=next_report){
                current=vgf_next(&queue,now);
                if(use_usb)vgf_usb_report(&current,pending_report);
                else vgf_report(&protocol,&current,n>0?in:NULL,n>0?(size_t)n:0,now,pending_report);
                have_report=1;report_started=now;
                ssize_t sent=hid_send(bt.itr,use_usb,pending_report);
                if(sent==(use_usb?8:50)){have_report=0;reports++;if(last_sent>0&&now-last_sent>max_gap)max_gap=now-last_sent;last_sent=now;next_report=now+((queue.count&&(use_usb||(protocol.vibration&&protocol.player)))?(use_usb?.001:.004):vgf_report_interval(&protocol,use_usb));}
                else if(sent<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){blocked++;next_report=now+.008;}else break;
                }
            }
            if(now-last_input>10)break;
        }
        /* One ack per iteration, for the newest accepted datagram, once every queued input has
           been written to HID. Earlier sequences in the batch go unacknowledged. Old apps never read acks. */
        if(ack_sequence&&!queue.count&&!have_report){uint8_t ack[VGF_ACK_SIZE];vgf_ack(key,ack_sequence,ack);(void)sendto(udp,ack,sizeof(ack),MSG_DONTWAIT,(struct sockaddr*)&ack_to,sizeof(ack_to));ack_sequence=0;}
        if(serial_ack_sequence&&!queue.count&&!have_report&&serial>=0){uint8_t ack[VGF_SERIAL_ACK];vgf_serial_ack(serial_ack_sequence,ack);ssize_t sent=write(serial,ack,sizeof(ack));if(sent>0)serial_ack_sequence=0;}
        if(now>=next_status&&!output_len){status_line(output,sizeof(output),detached?"detached":(connected?"connected":(listening?"connecting":"reconnecting")),use_usb);output_len=strlen(output);output_at=0;out_started=now;next_status=now+.5;}
        if(output_len){int n=SSL_write(ssl,output+output_at,(int)(output_len-output_at));if(n>0){output_at+=(size_t)n;output_want_read=0;if(output_at==output_len)output_at=output_len=0;}
            else {int e=SSL_get_error(ssl,n);if(e!=SSL_ERROR_WANT_READ&&e!=SSL_ERROR_WANT_WRITE)break;output_want_read=e==SSL_ERROR_WANT_READ;}
            if(output_len&&now-out_started>2)break;
        }
    }
 done:
    if(connected&&bt.itr>=0)hid_release(bt.itr,use_usb,&protocol);
    fprintf(stderr,"session end: input=%llu invalid=%llu reports=%llu blocked=%llu max_report_gap_ms=%.2f dropped_edges=%llu max_udp_gap_ms=%.2f udp_gaps_over_40ms=%llu serial_input=%llu serial_invalid=%llu\n",(unsigned long long)accepted,(unsigned long long)invalid,(unsigned long long)reports,(unsigned long long)blocked,max_gap*1000,(unsigned long long)queue.discarded,max_udp_gap*1000,(unsigned long long)udp_gaps,(unsigned long long)serial_accepted,(unsigned long long)serial_invalid);
    vgf_bt_close(&bt);if(udp>=0)close(udp);if(serial>=0)close(serial);OPENSSL_cleanse(key,32);if(lock>=0)close(lock);
}
static void client(SSL_CTX *ctx,int fd){
    struct timeval timeout={10,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    SSL *ssl=SSL_new(ctx);if(!ssl){close(fd);return;}SSL_set_fd(ssl,fd);
    /* Enrollment cannot hold a child indefinitely by trickling bytes. */
    signal(SIGALRM,SIG_DFL);alarm(15);json_object *request=NULL;char token[65]={0},id[65]={0};
    if(SSL_accept(ssl)!=1)goto done;request=read_json(ssl);
    const char *type=string(request,"type");if(!type||strcmp(type,"authenticate"))goto done;
    int issued=authenticate(request,token,id);if(issued<0){send_blocking(ssl,"{\"type\":\"error\",\"message\":\"파이 등록 정보가 일치하지 않거나 등록 시도가 너무 많습니다.\"}\n");goto done;}
    if(issued){char msg[128];snprintf(msg,sizeof(msg),"{\"type\":\"enrolled\",\"token\":\"%s\"}\n",token);if(send_blocking(ssl,msg))goto done;
        json_object *r=read_json(ssl);const char *t=string(r,"type");int ok=t&&!strcmp(t,"confirm");if(r)json_object_put(r);if(!ok||confirm(id))goto done;}
    alarm(0);session(ssl,fd,truth(request,"pair"));
 done:alarm(0);OPENSSL_cleanse(token,sizeof(token));if(request)json_object_put(request);SSL_free(ssl);close(fd);
}
int main(int argc,char **argv){
    if(argc==2&&!strcmp(argv[1],"--hid-descriptor")){vgf_usb_descriptor();return ferror(stdout)?1:0;}
    if(argc==3&&!strcmp(argv[1],"--state"))root=argv[2];else if(argc!=1){fprintf(stderr,"usage: %s [--state DIRECTORY]\n",argv[0]);return 2;}
    if(strlen(root)>400)return 2;umask(0077);signal(SIGPIPE,SIG_IGN);signal(SIGTERM,stop);signal(SIGINT,stop);
    failures=mmap(NULL,5*sizeof(double),PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANONYMOUS,-1,0);if(failures==MAP_FAILED)return 1;
    SSL_CTX *ctx=SSL_CTX_new(TLS_server_method());if(!ctx)return 1;SSL_CTX_set_min_proto_version(ctx,TLS1_2_VERSION);
    char cert[512],key[512];path_for(cert,"server.crt");path_for(key,"server.key");
    if(SSL_CTX_use_certificate_chain_file(ctx,cert)!=1||SSL_CTX_use_PrivateKey_file(ctx,key,SSL_FILETYPE_PEM)!=1||SSL_CTX_check_private_key(ctx)!=1){fprintf(stderr,"TLS identity load failed\n");return 1;}
    int fd=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0),yes=1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in sa={.sin_family=AF_INET,.sin_port=htons(24872),.sin_addr.s_addr=htonl(INADDR_ANY)};
    if(fd<0||bind(fd,(struct sockaddr*)&sa,sizeof(sa))<0||listen(fd,4)<0){perror("listen");return 1;}
    pid_t children[4]={0};fprintf(stderr,"VGF native controller ready, protocol 2\n");
    while(!stopping){
        for(int i=0;i<4;i++)if(children[i]&&waitpid(children[i],NULL,WNOHANG)>0)children[i]=0;
        struct pollfd p={fd,POLLIN,0};int r=poll(&p,1,250);if(r<0&&errno!=EINTR)break;if(r<=0)continue;
        int c=accept4(fd,NULL,NULL,SOCK_CLOEXEC);if(c<0)continue;int slot=-1;for(int i=0;i<4;i++)if(!children[i]){slot=i;break;}if(slot<0){close(c);continue;}
        pid_t pid=fork();if(pid==0){close(fd);client(ctx,c);SSL_CTX_free(ctx);_exit(0);}close(c);if(pid>0)children[slot]=pid;
    }
    close(fd);for(int i=0;i<4;i++)if(children[i])kill(children[i],SIGTERM);
    double deadline=now_s()+5;for(int i=0;i<4;i++)if(children[i]){while(waitpid(children[i],NULL,WNOHANG)==0&&now_s()<deadline)usleep(10000);if(waitpid(children[i],NULL,WNOHANG)==0){kill(children[i],SIGKILL);waitpid(children[i],NULL,0);}}
    SSL_CTX_free(ctx);munmap(failures,5*sizeof(double));return 0;
}
