CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-misleading-indentation
CPPFLAGS += $(shell pkg-config --cflags openssl json-c dbus-1 bluez)
LDLIBS += $(shell pkg-config --libs openssl json-c dbus-1 bluez) -lm
all: vgf-controller
service.o bluetooth.o protocol.o usb.o serial.o test_protocol.o test_auth.o test_session.o test_serial.o: protocol.h bluetooth.h usb.h serial.h
test_auth.o test_session.o: service.c
vgf-controller: service.o bluetooth.o protocol.o usb.o serial.o
	$(CC) $(CFLAGS) $^ $(LDLIBS) -o $@
check: test-protocol test-auth test-session test-serial
	./test-protocol
	./test-auth
	./test-session
	./test-serial
	sh ./test_usb_control.sh
test-protocol: test_protocol.o protocol.o usb.o
	$(CC) $(CFLAGS) $^ $(LDLIBS) -o $@
test-auth: test_auth.o bluetooth.o protocol.o usb.o serial.o
	$(CC) $(CFLAGS) $^ $(LDLIBS) -o $@
test-session: test_session.o bluetooth.o protocol.o usb.o serial.o
	$(CC) $(CFLAGS) $^ $(LDLIBS) -o $@
test-serial: test_serial.o serial.o
	$(CC) $(CFLAGS) $^ $(LDLIBS) -o $@
clean:
	rm -f *.o vgf-controller test-protocol test-auth test-session test-serial
.PHONY: all check clean
