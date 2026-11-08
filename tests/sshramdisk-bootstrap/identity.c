// Run the production identity/USB initializer against an in-memory IOKit registry.
#define VPHONE_BOOTSTRAP_TEST
#define main bootstrap_main
#define sleep bootstrap_sleep
#include "../../tools/sshramdisk-bootstrap/main.c"
#undef main
#include <assert.h>
#include <string.h>

static int chosen_present = 1, value_present = 1, data_type = 1;
static long data_length = 8;
static unsigned char ecid_bytes[16] = {0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01};
static char advertised[17];
static unsigned descriptions, controller_attempts, committed;
static int controller_status, commit_status, watchdog_present, watchdog_status;
static int32_t watchdog_value = -1;

io_registry_entry_t IORegistryEntryFromPath(mach_port_t port, const char *path) {
    assert(port == 0 && !strcmp(path, "IODeviceTree:/chosen"));
    return chosen_present;
}
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) {
    assert(entry == 1 && !strcmp(key, "unique-chip-id") && !allocator && !options);
    return value_present ? ecid_bytes : NULL;
}
unsigned long CFGetTypeID(CFTypeRef value) { assert(value == ecid_bytes); return data_type; }
unsigned long CFDataGetTypeID(void) { return 1; }
long CFDataGetLength(CFDataRef value) { assert(value == ecid_bytes); return data_length; }
const UInt8 *CFDataGetBytePtr(CFDataRef value) { assert(value == ecid_bytes); return ecid_bytes; }
CFStringRef CFStringCreateWithCString(CFAllocatorRef allocator, const char *value, unsigned int encoding) {
    assert(!allocator && encoding == kCFStringEncodingASCII);
    memcpy(advertised, value, sizeof(advertised));
    return advertised;
}
void CFRelease(CFTypeRef value) { assert(value); }
IOReturn IOObjectRelease(mach_port_t entry) { assert(entry == 1); return 0; }
CFMutableDictionaryRef IOServiceMatching(const char *name) { assert(!strcmp(name, "IOWatchDogTimer")); return (void *)name; }
io_service_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef match) { assert(!port && match); return watchdog_present; }
CFNumberRef CFNumberCreate(CFAllocatorRef allocator, int type, const void *value) {
    assert(!allocator && type == kCFNumberSInt32Type);
    watchdog_value = *(const int32_t *)value;
    return &watchdog_value;
}
IOReturn IORegistryEntrySetCFProperties(io_registry_entry_t entry, CFTypeRef value) {
    assert(entry == 1 && value == &watchdog_value);
    return watchdog_status;
}
USBDescription IOUSBDeviceDescriptionCreateWithType(CFAllocatorRef allocator, CFStringRef type) {
    assert(!allocator && !strcmp(type, "standardMuxOnly"));
    descriptions++;
    return (USBDescription)(uintptr_t)1;
}
void IOUSBDeviceDescriptionSetSerialString(USBDescription description, CFStringRef serial) {
    assert(description && serial == advertised);
}
IOReturn IOUSBDeviceControllerCreate(CFAllocatorRef allocator, USBController *controller) {
    assert(!allocator);
    controller_attempts++;
    *controller = controller_status ? NULL : (USBController)(uintptr_t)2;
    return controller_status;
}
IOReturn IOUSBDeviceControllerSetDescription(USBController controller, USBDescription description) {
    assert(controller && description);
    committed++;
    return commit_status;
}
unsigned int bootstrap_sleep(unsigned int seconds) { assert(seconds == 1); return 0; }

static void refused(void) {
    unsigned before = descriptions;
    assert(init_usb() == -1);
    assert(descriptions == before && committed == 0 && controller_attempts == 0);
}

int main(void) {
    chosen_present = 0; refused(); chosen_present = 1;
    value_present = 0; refused(); value_present = 1;
    data_type = 2; refused(); data_type = 1;
    data_length = 0; refused(); data_length = 7; refused(); data_length = 9; refused(); data_length = 8;
    memset(ecid_bytes, 0, sizeof(ecid_bytes)); refused();
    // An ECID with leading zeroes still has exactly sixteen uppercase hex digits.
    ecid_bytes[0] = 0xab;
    assert(init_usb() == 0 && !strcmp(advertised, "00000000000000AB"));
    assert(committed == 1);
    memcpy(ecid_bytes, (unsigned char[]){0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0xa1}, 8);
    assert(init_usb() == 0 && !strcmp(advertised, "A123456789ABCDEF"));
    controller_status = -1;
    unsigned before = controller_attempts;
    assert(init_usb() == -1 && controller_attempts == before + 30 && committed == 2);
    controller_status = 0; commit_status = -1;
    assert(init_usb() == -1);
    assert(disable_watchdog() == 0 && watchdog_value == -1);
    watchdog_present = 1;
    assert(disable_watchdog() == 0 && watchdog_value == 0);
    watchdog_status = -1;
    assert(disable_watchdog() == -1);
    puts("bootstrap identity and USB failure paths passed");
    return 0;
}
