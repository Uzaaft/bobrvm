#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1

#include "bobrvm.h"

#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct sigaction old_sigint;
static struct sigaction old_sigterm;

static void host_signal_handler(int signal_number) {
    (void)signal_number;
}

static void install_host_signal_handlers(void) {
    struct sigaction action = {0};

    action.sa_handler = host_signal_handler;
    assert(sigemptyset(&action.sa_mask) == 0);
    assert(sigaction(SIGINT, &action, &old_sigint) == 0);
    assert(sigaction(SIGTERM, &action, &old_sigterm) == 0);
}

static void assert_host_signal_handlers(void) {
    struct sigaction action = {0};

    assert(sigaction(SIGINT, NULL, &action) == 0);
    assert(action.sa_handler == host_signal_handler);
    assert(sigaction(SIGTERM, NULL, &action) == 0);
    assert(action.sa_handler == host_signal_handler);
}

static void restore_host_signal_handlers(void) {
    assert(sigaction(SIGINT, &old_sigint, NULL) == 0);
    assert(sigaction(SIGTERM, &old_sigterm, NULL) == 0);
}

static void test_configuration(void) {
    bobrvm_vm_config_s config = bobrvm_vm_config_defaults();

    assert(config.memory_bytes > 0);
    assert(config.vcpu_count > 0);
    assert(config.display_width > 0);
    assert(config.display_height > 0);
    assert(bobrvm_vm_config_validate(&config) == BOBRVM_OK);
    assert(bobrvm_vm_config_validate(NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);

    config.vcpu_count = 0;
    assert(bobrvm_vm_config_validate(&config) == BOBRVM_ERROR_INVALID_ARGUMENT);
}

static void test_filename_sanitization(void) {
    char output[32] = {0};
    size_t length = 0;

    assert(bobrvm_filename_sanitize(
               "NixOS VM:1",
               output,
               sizeof(output),
               &length
           ) == BOBRVM_OK);
    assert(length == strlen("NixOS_VM-1"));
    assert(memcmp(output, "NixOS_VM-1", length) == 0);
    assert(bobrvm_filename_sanitize("large", output, 4, &length) ==
           BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_filename_sanitize(NULL, output, sizeof(output), &length) ==
           BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_filename_sanitize("name", NULL, sizeof(output), &length) ==
           BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_filename_sanitize("name", output, sizeof(output), NULL) ==
           BOBRVM_ERROR_INVALID_ARGUMENT);
}

static void test_disk_errors(void) {
    uint64_t size = 0;

    assert(bobrvm_disk_create_sparse(NULL, 4096) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_disk_grow_raw(NULL, 4096) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_disk_logical_size(NULL, &size) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_disk_logical_size("/missing", NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);
}

static void test_disk_operations(void) {
    char directory[] = "/tmp/bobrvm-c-api-XXXXXX";
    char path[1024];
    char unsupported[1024];
    uint64_t size = 0;
    int length;

    assert(mkdtemp(directory) != NULL);
    length = snprintf(path, sizeof(path), "%s/disk.raw", directory);
    assert(length > 0 && (size_t)length < sizeof(path));
    length = snprintf(unsupported, sizeof(unsupported), "%s/disk.qcow2", directory);
    assert(length > 0 && (size_t)length < sizeof(unsupported));

    assert(bobrvm_disk_create_sparse(path, 4096) == BOBRVM_OK);
    assert(bobrvm_disk_logical_size(path, &size) == BOBRVM_OK);
    assert(size == 4096);
    assert(bobrvm_disk_create_sparse(path, 4096) == BOBRVM_ERROR_ALREADY_EXISTS);
    assert(bobrvm_disk_grow_raw(path, 8192) == BOBRVM_OK);
    assert(bobrvm_disk_logical_size(path, &size) == BOBRVM_OK);
    assert(size == 8192);
    assert(bobrvm_disk_grow_raw(path, 4096) == BOBRVM_ERROR_CANNOT_SHRINK);
    assert(bobrvm_disk_grow_raw(unsupported, 4096) == BOBRVM_ERROR_UNSUPPORTED_FORMAT);

    assert(unlink(path) == 0);
    assert(rmdir(directory) == 0);
}

static void test_null_handles(void) {
    bobrvm_guest_tools_status_s status = bobrvm_vm_guest_tools_status(NULL);

    assert(bobrvm_app_new(NULL) == NULL);
    bobrvm_app_destroy(NULL);
    bobrvm_app_tick(NULL);

    assert(bobrvm_vm_new(NULL, NULL) == NULL);
    assert(bobrvm_vm_start(NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_vm_console_write(NULL, NULL, 0) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_vm_console_resize(NULL, 80, 24) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(status.connection == BOBRVM_GUEST_TOOLS_DISCONNECTED);
    assert(status.capabilities == 0);
    assert(!bobrvm_vm_guest_management_ready(NULL));
    bobrvm_vm_shutdown_graceful(NULL);
    bobrvm_vm_guest_reboot(NULL);
    bobrvm_vm_guest_trim(NULL);
    bobrvm_vm_guest_sync_time(NULL);
    assert(bobrvm_vm_snapshot_quiesced(NULL, NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_vm_send_file(NULL, NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);
    bobrvm_vm_host_clipboard_changed(NULL);
    bobrvm_vm_kick_vcpu(NULL, UINT32_MAX);
    bobrvm_vm_force_exit_all(NULL);
    bobrvm_vm_stop(NULL);
    bobrvm_vm_request_stop(NULL);
    bobrvm_vm_finish_stop(NULL);
    bobrvm_vm_pause(NULL);
    bobrvm_vm_resume(NULL);
    bobrvm_vm_destroy(NULL);

    assert(bobrvm_macos_vm_new(NULL) == NULL);
    assert(bobrvm_macos_vm_start(NULL) == BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_macos_vm_state(NULL) == BOBRVM_VM_STATE_FAILED);
    assert(bobrvm_macos_vm_display_view(NULL) == NULL);
    assert(bobrvm_macos_vm_install(NULL, NULL, NULL, NULL) ==
           BOBRVM_ERROR_INVALID_ARGUMENT);
    assert(bobrvm_macos_vm_install_progress(NULL) == 0.0);
    bobrvm_macos_vm_stop(NULL);
    bobrvm_macos_vm_pause(NULL);
    bobrvm_macos_vm_resume(NULL);
    bobrvm_macos_vm_destroy(NULL);

    assert(bobrvm_surface_new(NULL, NULL, NULL, NULL) == NULL);
    bobrvm_surface_set_size(NULL, 1, 1);
    bobrvm_surface_request_display_size(NULL, 1, 1);
    bobrvm_surface_set_content_scale(NULL, 1.0, 1.0);
    bobrvm_surface_set_focus(NULL, true);
    bobrvm_surface_draw(NULL);
    bobrvm_surface_key(NULL, (bobrvm_key_event_s){0});
    bobrvm_surface_mouse_button(NULL, BOBRVM_MOUSE_LEFT, false);
    bobrvm_surface_mouse_pos(NULL, 0.0, 0.0);
    bobrvm_surface_mouse_scroll(NULL, 0.0, 0.0);
    bobrvm_surface_destroy(NULL);
}

int main(void) {
    bobrvm_build_mode_e build_mode;

    install_host_signal_handlers();
    bobrvm_init();
    assert_host_signal_handlers();

    assert(strcmp(bobrvm_version(), "0.1.0") == 0);
    build_mode = bobrvm_build_mode();
    assert(build_mode >= BOBRVM_BUILD_MODE_DEBUG);
    assert(build_mode <= BOBRVM_BUILD_MODE_RELEASE_SMALL);
    assert(bobrvm_is_debug() ==
           (build_mode == BOBRVM_BUILD_MODE_DEBUG ||
            build_mode == BOBRVM_BUILD_MODE_RELEASE_SAFE));
    test_configuration();
    test_filename_sanitization();
    test_disk_errors();
    test_disk_operations();
    test_null_handles();

    bobrvm_deinit();
    assert_host_signal_handlers();
    restore_host_signal_handlers();
    return 0;
}
