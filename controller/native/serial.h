#ifndef VGF_SERIAL_H
#define VGF_SERIAL_H
#include "protocol.h"
#include <stdint.h>
#include <stddef.h>
#define VGF_SERIAL_INPUT 29
#define VGF_SERIAL_ACK 13
/* Control frame: a5 5a, LEN 26, TYPE, 25-byte BODY, CRC over LEN..BODY (27B). */
#define VGF_SERIAL_CONTROL 31
#define VGF_SERIAL_CONTROL_LEN 26
#define VGF_SERIAL_BODY 25
#define VGF_SERIAL_MAX 31
#define VGF_SERIAL_VERSION 1
/* Mac -> Pi */
#define VGF_SERIAL_HELLO 0x01
#define VGF_SERIAL_USB 0x02
#define VGF_SERIAL_BYE 0x03
/* Pi -> Mac */
#define VGF_SERIAL_HELLO_REPLY 0x81
#define VGF_SERIAL_STATUS 0x82
#define VGF_SERIAL_USB_RESULT 0x83
#define VGF_SERIAL_PI_BYE 0x84
/* HELLO_REPLY result */
enum { VGF_SERIAL_HELLO_OK, VGF_SERIAL_HELLO_BUSY, VGF_SERIAL_HELLO_UNREGISTERED, VGF_SERIAL_HELLO_VERSION };
/* USB action and result */
enum { VGF_SERIAL_USB_DETACH=1, VGF_SERIAL_USB_ATTACH=2 };
enum { VGF_SERIAL_USB_ACCEPTED, VGF_SERIAL_USB_REJECTED };
/* STATUS state and backend */
enum { VGF_SERIAL_STARTING, VGF_SERIAL_CONNECTING, VGF_SERIAL_RECONNECTING, VGF_SERIAL_CONNECTED, VGF_SERIAL_DETACHED };
enum { VGF_SERIAL_BACKEND_NONE, VGF_SERIAL_BACKEND_USB, VGF_SERIAL_BACKEND_BLUETOOTH };
/* Pi BYE reason */
enum { VGF_SERIAL_BYE_ENDED, VGF_SERIAL_BYE_ATTACH, VGF_SERIAL_BYE_PEER_TIMEOUT, VGF_SERIAL_BYE_REPLACED,
       VGF_SERIAL_BYE_BLUETOOTH, VGF_SERIAL_BYE_USB_FAILED, VGF_SERIAL_BYE_SHUTDOWN };
typedef struct { uint8_t type; uint8_t body[VGF_SERIAL_BODY]; } vgf_serial_control;
typedef struct { uint8_t bytes[VGF_SERIAL_MAX]; size_t used, need; uint64_t last; } vgf_serial_parser;
uint16_t vgf_serial_crc(const uint8_t *, size_t);
void vgf_serial_frame(uint64_t, const vgf_input *, uint8_t[VGF_SERIAL_INPUT]);
/* -1 invalid, 0 need more, 1 input, 2 control. A NULL control consumes control frames as 0. */
int vgf_serial_byte(vgf_serial_parser *, uint8_t, vgf_input *, uint64_t *, vgf_serial_control *);
void vgf_serial_ack(uint64_t, uint8_t[VGF_SERIAL_ACK]);
/* A NULL body sends zeros. */
void vgf_serial_control_frame(uint8_t type, const uint8_t body[VGF_SERIAL_BODY], uint8_t out[VGF_SERIAL_CONTROL]);
int vgf_serial_open(const char *);
#endif
