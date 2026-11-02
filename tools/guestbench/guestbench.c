/*
 * guestbench: a fixed amount of typical iOS work, timed phase by phase, to measure the
 * emulator's speed inside the guest (tools/guestbench/run.sh). Deterministic: fixed seeds and
 * iteration counts, so two runs do the same work; only the time differs.
 *
 * Phases: branchy integer code through function pointers (indirect branches), malloc/free
 * churn, memcpy over a large buffer, system calls, file write/read, fresh memory mapped and
 * unmapped (page faults and TLB invalidations), CoreFoundation dictionaries and strings
 * (objc-style dispatch), float matrix multiplies (Neon), and 4 threads on one mutex.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint64_t rng = 88172645463325252ULL;
static inline uint64_t xs(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

/* 1. branchy code through function pointers */
typedef uint64_t (*opfn)(uint64_t, uint64_t);
static uint64_t op_add(uint64_t a, uint64_t b) { return a + b; }
static uint64_t op_xor(uint64_t a, uint64_t b) { return a ^ (b << 1); }
static uint64_t op_mul(uint64_t a, uint64_t b) { return a * (b | 1); }
static uint64_t op_rot(uint64_t a, uint64_t b) { return (a << (b & 31)) | (a >> (64 - (b & 31) - 1)); }
static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}
static uint64_t phase_branchy(void)
{
    opfn ops[4] = { op_add, op_xor, op_mul, op_rot };
    uint64_t acc = 1;
    for (int i = 0; i < 6000000; i++) {
        acc = ops[(acc >> 7) & 3](acc, (uint64_t)i);
    }
    uint64_t *v = malloc(200000 * sizeof(*v));
    for (int r = 0; r < 4; r++) {
        for (int i = 0; i < 200000; i++) {
            v[i] = xs();
        }
        qsort(v, 200000, sizeof(*v), cmp_u64);
        acc += v[r];
    }
    free(v);
    return acc;
}

/* 2. malloc/free churn */
static uint64_t phase_malloc(void)
{
    void *slot[1024] = { 0 };
    uint64_t acc = 0;
    for (int i = 0; i < 1500000; i++) {
        int k = xs() & 1023;
        free(slot[k]);
        size_t n = 16 + (xs() & 2047);
        slot[k] = malloc(n);
        memset(slot[k], i, 16);
        acc += n;
    }
    for (int k = 0; k < 1024; k++) {
        free(slot[k]);
    }
    return acc;
}

/* 3. memcpy over a large buffer */
static uint64_t phase_memcpy(void)
{
    size_t n = 32 << 20;
    char *a = malloc(n), *b = malloc(n);
    memset(a, 1, n);
    for (int r = 0; r < 12; r++) {
        memcpy(b, a, n);
        memcpy(a, b, n);
    }
    uint64_t acc = a[n / 2] + b[n / 3];
    free(a);
    free(b);
    return acc;
}

/* 4. system calls */
static uint64_t phase_syscall(void)
{
    uint64_t acc = 0;
    for (int i = 0; i < 150000; i++) {
        acc += getppid();
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        acc += ts.tv_nsec & 1;
    }
    return acc;
}

/* 5. file write/read */
static uint64_t phase_file(const char *dir)
{
    char path[512], buf[16384];
    uint64_t acc = 0;
    snprintf(path, sizeof path, "%s/guestbench.tmp", dir);
    memset(buf, 'x', sizeof buf);
    for (int r = 0; r < 40; r++) {
        int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
        for (int i = 0; i < 256; i++) {
            acc += write(fd, buf, sizeof buf);
        }
        lseek(fd, 0, SEEK_SET);
        while (read(fd, buf, sizeof buf) > 0) {
            acc++;
        }
        close(fd);
    }
    unlink(path);
    return acc;
}

/* 6. fresh memory: page faults, then unmap (TLB invalidations) */
static uint64_t phase_mmap(void)
{
    uint64_t acc = 0;
    for (int r = 0; r < 300; r++) {
        size_t n = 4 << 20;
        char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        for (size_t o = 0; o < n; o += 16384) {
            p[o] = (char)r;
        }
        acc += p[n - 16384];
        munmap(p, n);
    }
    return acc;
}

/* 7. CoreFoundation: dictionaries, strings, numbers */
static uint64_t phase_cf(void)
{
    uint64_t acc = 0;
    for (int r = 0; r < 25; r++) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        for (int i = 0; i < 4000; i++) {
            CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("key-%d-%d"), r, i);
            CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &i);
            CFDictionarySetValue(d, k, v);
            CFRelease(k);
            CFRelease(v);
        }
        for (int i = 0; i < 4000; i++) {
            CFStringRef k = CFStringCreateWithFormat(NULL, NULL, CFSTR("key-%d-%d"), r, i);
            acc += CFDictionaryContainsKey(d, k);
            CFRelease(k);
        }
        acc += CFDictionaryGetCount(d);
        CFRelease(d);
    }
    return acc;
}

/* 8. float matrix multiplies */
static uint64_t phase_float(void)
{
    enum { N = 96 };
    static float a[N][N], b[N][N], c[N][N];
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            a[i][j] = (float)((i * 7 + j) % 13) * 0.5f;
            b[i][j] = (float)((i + j * 3) % 11) * 0.25f;
        }
    }
    for (int r = 0; r < 30; r++) {
        for (int i = 0; i < N; i++) {
            for (int j = 0; j < N; j++) {
                float s = 0;
                for (int k = 0; k < N; k++) {
                    s += a[i][k] * b[k][j];
                }
                c[i][j] = s;
            }
        }
        a[r % N][0] = c[0][r % N] * 1e-3f;
    }
    return (uint64_t)c[N / 2][N / 3];
}

/* 9. four threads on one mutex */
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t shared;
static void *locker(void *arg)
{
    (void)arg;
    for (int i = 0; i < 150000; i++) {
        pthread_mutex_lock(&mu);
        shared += i;
        pthread_mutex_unlock(&mu);
    }
    return NULL;
}
static uint64_t phase_lock(void)
{
    pthread_t t[4];
    for (int i = 0; i < 4; i++) {
        pthread_create(&t[i], NULL, locker, NULL);
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(t[i], NULL);
    }
    return shared;
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    struct { const char *name; uint64_t (*fn)(void); } phases[] = {
        { "branchy", phase_branchy }, { "malloc", phase_malloc }, { "memcpy", phase_memcpy },
        { "syscall", phase_syscall }, { "file", NULL }, { "mmap", phase_mmap },
        { "cf", phase_cf }, { "float", phase_float }, { "lock", phase_lock },
    };
    double total = 0;
    uint64_t check = 0;
    printf("guestbench");
    for (unsigned i = 0; i < sizeof phases / sizeof phases[0]; i++) {
        double t0 = now();
        check += phases[i].fn ? phases[i].fn() : phase_file(dir);
        double dt = now() - t0;
        total += dt;
        printf(" %s=%.3f", phases[i].name, dt);
    }
    printf(" total=%.3f check=%llx\n", total, (unsigned long long)check);
    return 0;
}
