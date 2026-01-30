/**
 * os_log helper implementation.
 *
 * The os_log() function in Apple's os/log.h is a macro, so we need
 * a C wrapper to call it from Zig.
 *
 * Pattern follows Ghostty's pkg/macos/os/log.c.
 */

#include <os/log.h>

/**
 * Log a message with the given type.
 *
 * @param log os_log_t handle created with os_log_create()
 * @param type os_log_type_t (OS_LOG_TYPE_DEFAULT, _INFO, _DEBUG, _ERROR, _FAULT)
 * @param message Null-terminated string to log
 */
void bobrvm_os_log_with_type(os_log_t log, os_log_type_t type, const char* message) {
    os_log_with_type(log, type, "%{public}s", message);
}
