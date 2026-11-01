#ifndef VGF_SERIAL_H
#define VGF_SERIAL_H
#include "protocol.h"
#include <stdint.h>
#include <stddef.h>
#define VGF_SERIAL_INPUT 29
#define VGF_SERIAL_ACK 13
typedef struct { uint8_t bytes[VGF_SERIAL_INPUT]; size_t used; uint64_t last; } vgf_serial_parser;
uint16_t vgf_serial_crc(const uint8_t *, size_t);
void vgf_serial_frame(uint64_t, const vgf_input *, uint8_t[VGF_SERIAL_INPUT]);
int vgf_serial_byte(vgf_serial_parser *, uint8_t, vgf_input *, uint64_t *);
void vgf_serial_ack(uint64_t, uint8_t[VGF_SERIAL_ACK]);
int vgf_serial_open(const char *);
#endif
