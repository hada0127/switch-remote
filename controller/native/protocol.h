/* SPDX-License-Identifier: MIT -- Switch report layout adapted from vendored NXBT. */
#ifndef VGF_PROTOCOL_H
#define VGF_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#define VGF_BUTTONS 18
#define VGF_PAYLOAD_SIZE 16
#define VGF_PACKET_SIZE 56
#define VGF_REPORT_SIZE 50
#define VGF_QUEUE_SIZE 32
/* Ack: uint64 sequence, "VGFA", HMAC-SHA256 of the first 12 bytes. Measurement only. */
#define VGF_ACK_SIZE 44
/* Wire order is shared with Swift's binaryInputPayload. */
enum { A,B,X,Y,L,R,ZL,ZR,PLUS,MINUS,HOME,CAPTURE,LS,RS,UP,DOWN,LEFT,RIGHT };
typedef struct { uint32_t buttons; int16_t axis[4]; } vgf_input;
typedef struct { vgf_input input; double received; } vgf_event;
typedef struct {
    vgf_event events[VGF_QUEUE_SIZE]; unsigned head,count;
    vgf_input held; double last_input; uint64_t coalesced,discarded;
} vgf_queue;
typedef struct {
    uint8_t address[6], timer, mode, player;
    bool device_info, imu, vibration;
    double last_report;
} vgf_protocol;
double vgf_report_interval(const vgf_protocol *, int usb);
void vgf_enqueue(vgf_queue *, const vgf_input *, double);
vgf_input vgf_next(vgf_queue *, double);
void vgf_report(vgf_protocol *, const vgf_input *, const uint8_t *, size_t, double, uint8_t out[VGF_REPORT_SIZE]);
int vgf_decode(const uint8_t *, size_t, const uint8_t key[32], uint64_t *, vgf_input *);
void vgf_ack(const uint8_t key[32], uint64_t, uint8_t out[VGF_ACK_SIZE]);
#endif
