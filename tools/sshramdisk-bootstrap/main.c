// SPDX-License-Identifier: MIT
// The restore launchd starts this as /usr/local/bin/restored_external.
#ifdef VPHONE_BOOTSTRAP_TEST
#include "platform.h"
#else
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#endif
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

// These IOKit SPIs are exported by the restore ramdisk, although the public iOS
// SDK does not declare all of them as available to ordinary applications.
typedef mach_port_t io_registry_entry_t;
typedef mach_port_t io_service_t;
typedef int IOReturn;
extern io_registry_entry_t IORegistryEntryFromPath(mach_port_t, const char *);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
extern IOReturn IORegistryEntrySetCFProperties(io_registry_entry_t, CFTypeRef);
extern IOReturn IOObjectRelease(mach_port_t);
typedef struct __IOUSBDeviceDescription *USBDescription;
typedef struct __IOUSBDeviceController *USBController;
extern USBDescription IOUSBDeviceDescriptionCreateWithType(CFAllocatorRef, CFStringRef);
extern void IOUSBDeviceDescriptionSetSerialString(USBDescription, CFStringRef);
extern IOReturn IOUSBDeviceControllerCreate(CFAllocatorRef, USBController *);
extern IOReturn IOUSBDeviceControllerSetDescription(USBController, USBDescription);

static int own_serial(char serial[17]) {
    io_registry_entry_t chosen = IORegistryEntryFromPath(MACH_PORT_NULL, "IODeviceTree:/chosen");
    if (!chosen) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(chosen, CFSTR("unique-chip-id"), NULL, 0);
    IOObjectRelease(chosen);
    if (!value) return -1;
    uint64_t ecid = 0;
    if (CFGetTypeID(value) == CFDataGetTypeID() && CFDataGetLength(value) == 8) {
        const UInt8 *bytes = CFDataGetBytePtr(value);
        // Device-tree integers are little-endian, including on the arm64 guest.
        for (unsigned i = 0; i < 8; i++) ecid |= (uint64_t)bytes[i] << (i * 8);
    }
    CFRelease(value);
    if (!ecid) return -1;
    return snprintf(serial, 17, "%016" PRIX64, ecid) == 16 ? 0 : -1;
}

static int disable_watchdog(void) {
    io_service_t watchdog = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOWatchDogTimer"));
    if (!watchdog) return 0;
    int32_t zero = 0;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt32Type, &zero);
    IOReturn status = value ? IORegistryEntrySetCFProperties(watchdog, value) : -1;
    if (value) CFRelease(value);
    IOObjectRelease(watchdog);
    return status == 0 ? 0 : -1;
}

static int init_usb(void) {
    char serial[17];
    if (own_serial(serial)) {
        fprintf(stderr, "SSH ramdisk: missing, malformed, or zero chosen ECID; refusing USB initialization\n");
        return -1;
    }
    USBDescription description = IOUSBDeviceDescriptionCreateWithType(NULL, CFSTR("standardMuxOnly"));
    if (!description) return -1;
    CFStringRef identity = CFStringCreateWithCString(NULL, serial, kCFStringEncodingASCII);
    if (!identity) { CFRelease(description); return -1; }
    IOUSBDeviceDescriptionSetSerialString(description, identity);
    CFRelease(identity);
    USBController controller = NULL;
    IOReturn status = -1;
    for (unsigned attempt = 0; attempt < 30; attempt++) {
        status = IOUSBDeviceControllerCreate(NULL, &controller);
        if (!status && controller) break;
        if (controller) CFRelease(controller);
        controller = NULL;
        sleep(1);
    }
    if (!status && controller) status = IOUSBDeviceControllerSetDescription(controller, description);
    else status = -1;
    if (controller) CFRelease(controller);
    CFRelease(description);
    if (status) return -1;
    printf("SSH ramdisk: USB serial %s\n", serial);
    fflush(stdout);
    return 0;
}

static int serve_ssh(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    int enabled = 1;
    struct sockaddr_in address = {0};
#ifdef __APPLE__
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(22);
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 16)) {
        close(listener);
        return -1;
    }
    // Dropbear retains its existing inetd contract: a fresh process per socket.
    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    for (;;) {
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) { if (errno == EINTR) continue; close(listener); return -1; }
        pid_t child = fork();
        if (!child) {
            signal(SIGCHLD, SIG_DFL);
            signal(SIGPIPE, SIG_DFL);
            close(listener);
            for (int fd = 0; fd <= 2; fd++) if (dup2(connection, fd) < 0) _exit(126);
            if (connection > 2) close(connection);
            execl("/usr/local/bin/dropbear", "dropbear", "-i", (char *)NULL);
            _exit(127);
        }
        close(connection);
        if (child < 0) { close(listener); return -1; }
    }
}

int main(void) {
    if (disable_watchdog()) { fprintf(stderr, "SSH ramdisk: cannot disable watchdog\n"); return 1; }
    if (init_usb()) { fprintf(stderr, "SSH ramdisk: USB initialization failed\n"); return 1; }
    if (serve_ssh()) { perror("SSH ramdisk: SSH listener"); return 1; }
    return 0;
}
