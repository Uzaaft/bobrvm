/*
 * Copyright (C) 2026 polymath labs AS
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#pragma once

#include <stddef.h>

typedef struct BobrvmFprintTransport BobrvmFprintTransport;

typedef enum {
    BOBRVM_FPRINT_SUCCESS = 1,
    BOBRVM_FPRINT_NO_MATCH = 2,
    BOBRVM_FPRINT_CANCELLED = 3,
    BOBRVM_FPRINT_UNAVAILABLE = 4,
    BOBRVM_FPRINT_LOCKED = 5,
    BOBRVM_FPRINT_FAILED = 6,
    BOBRVM_FPRINT_INVALID_ARGUMENT = -1,
    BOBRVM_FPRINT_BUSY = -2,
    BOBRVM_FPRINT_SOCKET_FAILED = -3,
    BOBRVM_FPRINT_CONNECT_FAILED = -4,
    BOBRVM_FPRINT_WRITE_FAILED = -5,
    BOBRVM_FPRINT_TIMED_OUT = -6,
    BOBRVM_FPRINT_CONNECTION_CLOSED = -7,
    BOBRVM_FPRINT_INVALID_RESPONSE = -8,
} BobrvmFprintResult;

BobrvmFprintTransport *bobrvm_fprint_transport_create(void);
void bobrvm_fprint_transport_destroy(BobrvmFprintTransport *transport);
BobrvmFprintResult bobrvm_fprint_transport_request(
    BobrvmFprintTransport *transport,
    unsigned char operation,
    const char *username,
    size_t username_length,
    const char *socket_path);
void bobrvm_fprint_transport_cancel(BobrvmFprintTransport *transport);
