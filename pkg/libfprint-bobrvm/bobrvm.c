/*
 * Host-backed fingerprint driver for bobrvm guests.
 *
 * Copyright (C) 2026 polymath labs AS
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#define FP_COMPONENT "bobrvm"

#include "bobrvm_transport.h"
#include "fpi-device.h"
#include "fpi-log.h"

#include <string.h>

typedef enum {
    BOBRVM_OPERATION_ENROLL = 1,
    BOBRVM_OPERATION_VERIFY = 2,
} BobrvmOperation;

typedef struct {
    BobrvmOperation operation;
    gchar *username;
} BobrvmRequest;

typedef struct _FpDeviceBobrvm {
    FpDevice parent;
    BobrvmFprintTransport *transport;
} FpDeviceBobrvm;

typedef FpDeviceClass FpDeviceBobrvmClass;

G_DEFINE_TYPE(FpDeviceBobrvm, fpi_device_bobrvm, FP_TYPE_DEVICE)

static void
request_free(gpointer data)
{
    BobrvmRequest *request = data;

    g_free(request->username);
    g_free(request);
}

static GError *
transport_error(BobrvmFprintResult result)
{
    GIOErrorEnum code = G_IO_ERROR_FAILED;
    const gchar *message = "The bobrvm fingerprint request failed";

    switch (result) {
    case BOBRVM_FPRINT_INVALID_ARGUMENT:
        code = G_IO_ERROR_INVALID_ARGUMENT;
        message = "Invalid bobrvm fingerprint request";
        break;
    case BOBRVM_FPRINT_BUSY:
        code = G_IO_ERROR_BUSY;
        message = "Another bobrvm fingerprint request is active";
        break;
    case BOBRVM_FPRINT_SOCKET_FAILED:
        message = "Unable to create the bobrvm fingerprint socket";
        break;
    case BOBRVM_FPRINT_CONNECT_FAILED:
        code = G_IO_ERROR_CONNECTION_REFUSED;
        message = "Unable to connect to the bobrvm fingerprint service";
        break;
    case BOBRVM_FPRINT_WRITE_FAILED:
        message = "Unable to send the bobrvm fingerprint request";
        break;
    case BOBRVM_FPRINT_TIMED_OUT:
        code = G_IO_ERROR_TIMED_OUT;
        message = "The macOS Touch ID request timed out";
        break;
    case BOBRVM_FPRINT_CONNECTION_CLOSED:
        code = G_IO_ERROR_CONNECTION_CLOSED;
        message = "The bobrvm fingerprint connection closed";
        break;
    case BOBRVM_FPRINT_INVALID_RESPONSE:
        code = G_IO_ERROR_INVALID_DATA;
        message = "Invalid bobrvm fingerprint response";
        break;
    case BOBRVM_FPRINT_CANCELLED:
        code = G_IO_ERROR_CANCELLED;
        message = "The bobrvm fingerprint request was cancelled";
        break;
    default:
        break;
    }
    return g_error_new_literal(G_IO_ERROR, code, message);
}

static void
request_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable)
{
    FpDeviceBobrvm *self = source;
    BobrvmRequest *request = task_data;
    const gchar *socket_path = fpi_device_get_virtual_env(FP_DEVICE(self));
    BobrvmFprintResult result;

    if (self->transport == NULL || socket_path == NULL) {
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_NOT_INITIALIZED,
                                "The bobrvm fingerprint transport is unavailable");
        return;
    }
    result = bobrvm_fprint_transport_request(self->transport, request->operation,
                                              request->username, strlen(request->username),
                                              socket_path);
    if (result == BOBRVM_FPRINT_CANCELLED && g_cancellable_is_cancelled(cancellable)) {
        g_task_return_error(task, transport_error(result));
        return;
    }
    if (result < BOBRVM_FPRINT_SUCCESS) {
        g_task_return_error(task, transport_error(result));
        return;
    }
    g_task_return_int(task, result);
}

static void
complete_enroll(FpDevice *device, BobrvmFprintResult result, GError *error)
{
    FpPrint *print = NULL;

    if (error != NULL) {
        fpi_device_enroll_complete(device, NULL, error);
        return;
    }
    if (result != BOBRVM_FPRINT_SUCCESS) {
        FpDeviceError code = result == BOBRVM_FPRINT_UNAVAILABLE
                                 ? FP_DEVICE_ERROR_NOT_SUPPORTED
                                 : FP_DEVICE_ERROR_GENERAL;
        fpi_device_enroll_complete(device, NULL, fpi_device_error_new(code));
        return;
    }

    fpi_device_get_enroll_data(device, &print);
    fpi_print_set_type(print, FPI_PRINT_RAW);
    g_object_set(print, "fpi-data", g_variant_new_string("macos-touch-id"), NULL);
    fpi_device_enroll_progress(device, 1, print, NULL);
    fpi_device_enroll_complete(device, g_object_ref(print), NULL);
}

static void
complete_verify(FpDevice *device, BobrvmFprintResult result, GError *error)
{
    if (error != NULL) {
        fpi_device_verify_complete(device, error);
        return;
    }
    if (result == BOBRVM_FPRINT_SUCCESS || result == BOBRVM_FPRINT_NO_MATCH) {
        fpi_device_verify_report(device,
                                 result == BOBRVM_FPRINT_SUCCESS
                                     ? FPI_MATCH_SUCCESS
                                     : FPI_MATCH_FAIL,
                                 NULL, NULL);
        fpi_device_verify_complete(device, NULL);
        return;
    }

    FpDeviceError code = result == BOBRVM_FPRINT_UNAVAILABLE
                             ? FP_DEVICE_ERROR_NOT_SUPPORTED
                             : FP_DEVICE_ERROR_GENERAL;
    fpi_device_verify_complete(device, fpi_device_error_new(code));
}

static void
request_done(GObject *source, GAsyncResult *async_result, gpointer user_data)
{
    FpDevice *device = FP_DEVICE(source);
    BobrvmOperation operation = GPOINTER_TO_UINT(user_data);
    g_autoptr(GError) error = NULL;
    gint result = g_task_propagate_int(G_TASK(async_result), &error);

    if (operation == BOBRVM_OPERATION_ENROLL)
        complete_enroll(device, result, g_steal_pointer(&error));
    else
        complete_verify(device, result, g_steal_pointer(&error));
}

static void
start_request(FpDevice *device, BobrvmOperation operation)
{
    FpPrint *print = NULL;
    const gchar *username;
    BobrvmRequest *request;
    GTask *task;

    if (operation == BOBRVM_OPERATION_ENROLL)
        fpi_device_get_enroll_data(device, &print);
    else
        fpi_device_get_verify_data(device, &print);
    username = fp_print_get_username(print);
    if (username == NULL || *username == '\0') {
        fpi_device_action_error(device, fpi_device_error_new(FP_DEVICE_ERROR_DATA_INVALID));
        return;
    }

    request = g_new0(BobrvmRequest, 1);
    request->operation = operation;
    request->username = g_strdup(username);
    task = g_task_new(device, fpi_device_get_cancellable(device), request_done,
                      GUINT_TO_POINTER(operation));
    g_task_set_task_data(task, request, request_free);
    g_task_run_in_thread(task, request_thread);
    g_object_unref(task);
}

static void
dev_probe(FpDevice *device)
{
    fpi_device_probe_complete(device, "0", "Mac Touch ID", NULL);
}

static void
dev_open(FpDevice *device)
{
    fpi_device_open_complete(device, NULL);
}

static void
dev_close(FpDevice *device)
{
    fpi_device_close_complete(device, NULL);
}

static void
dev_enroll(FpDevice *device)
{
    start_request(device, BOBRVM_OPERATION_ENROLL);
}

static void
dev_verify(FpDevice *device)
{
    start_request(device, BOBRVM_OPERATION_VERIFY);
}

static void
dev_cancel(FpDevice *device)
{
    FpDeviceBobrvm *self = (FpDeviceBobrvm *) device;

    if (self->transport != NULL)
        bobrvm_fprint_transport_cancel(self->transport);
}

static void
fpi_device_bobrvm_finalize(GObject *object)
{
    FpDeviceBobrvm *self = (FpDeviceBobrvm *) object;

    bobrvm_fprint_transport_destroy(self->transport);
    G_OBJECT_CLASS(fpi_device_bobrvm_parent_class)->finalize(object);
}

static void
fpi_device_bobrvm_init(FpDeviceBobrvm *self)
{
    self->transport = bobrvm_fprint_transport_create();
}

static const FpIdEntry driver_ids[] = {
    { .virtual_envvar = "FP_BOBRVM_TOUCH_ID" },
    { .virtual_envvar = NULL },
};

static void
fpi_device_bobrvm_class_init(FpDeviceBobrvmClass *klass)
{
    FpDeviceClass *device_class = FP_DEVICE_CLASS(klass);
    GObjectClass *object_class = G_OBJECT_CLASS(klass);

    object_class->finalize = fpi_device_bobrvm_finalize;
    device_class->id = FP_COMPONENT;
    device_class->full_name = "Mac Touch ID";
    device_class->type = FP_DEVICE_TYPE_VIRTUAL;
    device_class->id_table = driver_ids;
    device_class->nr_enroll_stages = 1;
    device_class->scan_type = FP_SCAN_TYPE_PRESS;
    device_class->probe = dev_probe;
    device_class->open = dev_open;
    device_class->close = dev_close;
    device_class->enroll = dev_enroll;
    device_class->verify = dev_verify;
    device_class->cancel = dev_cancel;
    fpi_device_class_auto_initialize_features(device_class);
}
