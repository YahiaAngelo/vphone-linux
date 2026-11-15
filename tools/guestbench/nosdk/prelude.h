/* The Darwin (arm64 iOS) declarations guestbench.c uses, for building it without the SDK (build-nosdk.sh). */
typedef unsigned long size_t;
typedef long ssize_t;
typedef long long off_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;
typedef unsigned int uint32_t;
typedef int int32_t;
typedef unsigned char uint8_t;
typedef unsigned long uintptr_t;
#define NULL ((void *)0)

struct timespec { long tv_sec; long tv_nsec; };
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 6
int clock_gettime(int clock_id, struct timespec *tp);

int printf(const char *fmt, ...);
int snprintf(char *buf, size_t n, const char *fmt, ...);
void *malloc(size_t n);
void free(void *p);
void *memset(void *p, int c, size_t n);
void *memcpy(void *d, const void *s, size_t n);
int strcmp(const char *a, const char *b);
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));

#define O_RDWR 0x0002
#define O_CREAT 0x0200
#define O_TRUNC 0x0400
#define SEEK_SET 0
int open(const char *path, int flags, ...);
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
off_t lseek(int fd, off_t off, int whence);
int close(int fd);
int unlink(const char *path);
int getppid(void);

#define PROT_READ 0x01
#define PROT_WRITE 0x02
#define MAP_PRIVATE 0x0002
#define MAP_ANON 0x1000
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);

typedef struct _opaque_pthread_t *pthread_t;
typedef struct { long __sig; char __opaque[56]; } pthread_mutex_t;
#define PTHREAD_MUTEX_INITIALIZER { 0x32AAABA7, { 0 } }
int pthread_create(pthread_t *t, const void *attr, void *(*fn)(void *), void *arg);
int pthread_join(pthread_t t, void **ret);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);

/* CoreFoundation */
typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFNumber *CFNumberRef;
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef long CFIndex;
typedef unsigned char Boolean;
typedef struct { CFIndex version; const void *f[5]; } CFDictionaryKeyCallBacks;
typedef struct { CFIndex version; const void *f[4]; } CFDictionaryValueCallBacks;
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
#define kCFNumberIntType 9
#define kCFStringEncodingUTF8 0x08000100
CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef a, CFIndex cap, const CFDictionaryKeyCallBacks *k,
                                                 const CFDictionaryValueCallBacks *v);
CFStringRef CFStringCreateWithFormat(CFAllocatorRef a, CFDictionaryRef opts, CFStringRef fmt, ...);
CFStringRef CFStringCreateWithCString(CFAllocatorRef a, const char *s, uint32_t enc);
CFNumberRef CFNumberCreate(CFAllocatorRef a, CFIndex type, const void *v);
void CFDictionarySetValue(CFMutableDictionaryRef d, const void *k, const void *v);
Boolean CFDictionaryContainsKey(CFDictionaryRef d, const void *k);
CFIndex CFDictionaryGetCount(CFDictionaryRef d);
void CFRelease(CFTypeRef t);

/* The SDK's CFSTR is a constant string; this one is made once per literal. */
static inline CFStringRef gb_cfstr(const char *s)
{
    static const char *last;
    static CFStringRef str;

    if (s != last) {
        str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
        last = s;
    }
    return str;
}
#define CFSTR(s) gb_cfstr(s)
