#include <stddef.h>
#include <stdint.h>
typedef uint32_t mach_port_t;
#define MACH_PORT_NULL 0
typedef const void *CFTypeRef;
typedef const void *CFAllocatorRef;
typedef const void *CFDictionaryRef;
typedef void *CFMutableDictionaryRef;
typedef const char *CFStringRef;
typedef const void *CFDataRef;
typedef const void *CFNumberRef;
typedef unsigned char UInt8;
#define CFSTR(value) (value)
#define kCFStringEncodingASCII 0
#define kCFNumberSInt32Type 0
extern unsigned long CFGetTypeID(CFTypeRef);
extern unsigned long CFDataGetTypeID(void);
extern long CFDataGetLength(CFDataRef);
extern const UInt8 *CFDataGetBytePtr(CFDataRef);
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, unsigned int);
extern CFNumberRef CFNumberCreate(CFAllocatorRef, int, const void *);
extern void CFRelease(CFTypeRef);
