// Traceroute Android bằng ICMP ping-socket (SOCK_DGRAM, IPPROTO_ICMP).
//
// Android cho phép app thường (không root) mở loại socket này nhờ sysctl
// net.ipv4.ping_group_range bao trùm UID của app — đây chính là cơ chế mà
// lệnh `ping` không-root trên Android/Linux dùng. Không phải raw socket
// (SOCK_RAW), nên không cần CAP_NET_RAW.
//
// Để lấy được ICMP "Time Exceeded" từ router giữa đường (không phải Echo
// Reply từ đích), kernel Linux giao nó qua error queue của socket
// (setsockopt IP_RECVERR + recvmsg MSG_ERRQUEUE), KHÔNG qua recv() thường.
// API này không có trong android.system.Os của Android SDK — đó là lý do
// bắt buộc phải viết native thay vì thuần Kotlin.
//
// Viết cho: implement thêm Android traceroute native, dùng làm fallback khi
// exec binary `ping` bị một số ROM chặn (xem PingTtlTraceroute._execAvailable
// ở phía Dart).

#include <arpa/inet.h>
#include <errno.h>
#include <jni.h>
#include <linux/errqueue.h>
#include <linux/icmp.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int ttl;
    char address[INET_ADDRSTRLEN];
    int hasAddress;
    double rttMs;
    int hasRtt;
    int isDestination;
} Hop;

static unsigned short icmp_checksum(void *data, int len) {
    unsigned short *buf = (unsigned short *) data;
    unsigned int sum = 0;
    for (; len > 1; len -= 2) sum += *buf++;
    if (len == 1) sum += *(unsigned char *) buf;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return (unsigned short) ~sum;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// Mở ping-socket và bind port 0 — kernel gán "port", đây cũng chính là
// identifier ICMP mà nó dùng để demux gói đi/về của socket này.
static int open_ping_socket(unsigned short *identOut) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) return -1;

    int on = 1;
    setsockopt(fd, IPPROTO_IP, IP_RECVERR, &on, sizeof(on));

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = 0;

    if (bind(fd, (struct sockaddr *) &local, sizeof(local)) < 0) {
        close(fd);
        return -1;
    }

    socklen_t len = sizeof(local);
    if (getsockname(fd, (struct sockaddr *) &local, &len) == 0) {
        *identOut = ntohs(local.sin_port);
    } else {
        *identOut = (unsigned short) (getpid() & 0xFFFF);
    }
    return fd;
}

// Trả 1 nếu bắt được hop (điền *hop), 0 nếu timeout, -1 nếu lỗi fatal (dừng
// hẳn vòng lặp — ví dụ setsockopt/sendto hỏng do socket chết).
static int probe_one(int fd, struct sockaddr_in *dest, int ttl, int timeoutMs,
                      unsigned short ident, Hop *hop) {
    memset(hop, 0, sizeof(*hop));
    hop->ttl = ttl;

    if (setsockopt(fd, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) < 0) return -1;

    struct icmphdr icmp;
    memset(&icmp, 0, sizeof(icmp));
    icmp.type = ICMP_ECHO;
    icmp.code = 0;
    icmp.un.echo.id = htons(ident);
    icmp.un.echo.sequence = htons((unsigned short) ttl);
    icmp.checksum = 0;
    icmp.checksum = icmp_checksum(&icmp, sizeof(icmp));

    double sentAt = now_ms();
    if (sendto(fd, &icmp, sizeof(icmp), 0, (struct sockaddr *) dest, sizeof(*dest)) < 0) {
        return -1;
    }

    int remaining = timeoutMs;
    struct pollfd pfd = {.fd = fd, .events = POLLIN};

    while (remaining > 0) {
        double waitStart = now_ms();
        int pr = poll(&pfd, 1, remaining);
        if (pr <= 0) return 0; // timeout hoặc interrupted hết giờ luôn

        if (pfd.revents & POLLERR) {
            char cbuf[512];
            char databuf[128];
            struct iovec iov = {databuf, sizeof(databuf)};
            struct msghdr msg;
            memset(&msg, 0, sizeof(msg));
            msg.msg_iov = &iov;
            msg.msg_iovlen = 1;
            msg.msg_control = cbuf;
            msg.msg_controllen = sizeof(cbuf);

            ssize_t n = recvmsg(fd, &msg, MSG_ERRQUEUE);
            double rtt = now_ms() - sentAt;
            if (n >= 0) {
                for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
                     cmsg = CMSG_NXTHDR(&msg, cmsg)) {
                    if (cmsg->cmsg_level != IPPROTO_IP || cmsg->cmsg_type != IP_RECVERR) continue;

                    struct sock_extended_err *ee = (struct sock_extended_err *) CMSG_DATA(cmsg);
                    if (ee->ee_origin != SO_EE_ORIGIN_ICMP) continue;

                    struct sockaddr_in *offender = (struct sockaddr_in *) SO_EE_OFFENDER(ee);
                    hop->hasAddress = 1;
                    inet_ntop(AF_INET, &offender->sin_addr, hop->address, sizeof(hop->address));
                    hop->hasRtt = 1;
                    hop->rttMs = rtt;
                    // Type 3 = Destination Unreachable: hết đường đi tiếp được,
                    // coi như đã chạm biên — giống hành vi của bản Dart (ping).
                    if (ee->ee_type == ICMP_DEST_UNREACH) hop->isDestination = 1;
                    return 1;
                }
            }
        }

        if (pfd.revents & POLLIN) {
            char databuf[512];
            struct sockaddr_in from;
            socklen_t fromlen = sizeof(from);
            ssize_t n = recvfrom(fd, databuf, sizeof(databuf), 0, (struct sockaddr *) &from, &fromlen);
            double rtt = now_ms() - sentAt;
            if (n >= (ssize_t) sizeof(struct icmphdr)) {
                struct icmphdr *reply = (struct icmphdr *) databuf;
                if (reply->type == ICMP_ECHOREPLY) {
                    hop->hasAddress = 1;
                    inet_ntop(AF_INET, &from.sin_addr, hop->address, sizeof(hop->address));
                    hop->hasRtt = 1;
                    hop->rttMs = rtt;
                    hop->isDestination = 1;
                    return 1;
                }
            }
        }

        remaining -= (int) (now_ms() - waitStart);
    }
    return 0;
}

static jstring make_error_json(JNIEnv *env, const char *message) {
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", message);
    return (*env)->NewStringUTF(env, buf);
}

static jstring native_trace(JNIEnv *env, jobject thiz, jstring jhost, jint maxHops, jint timeoutMs) {
    (void) thiz;
    const char *host = (*env)->GetStringUTFChars(env, jhost, NULL);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;

    struct addrinfo *res = NULL;
    int gaierr = getaddrinfo(host, NULL, &hints, &res);
    (*env)->ReleaseStringUTFChars(env, jhost, host);

    if (gaierr != 0 || res == NULL) {
        if (res) freeaddrinfo(res);
        return make_error_json(env, "resolve_failed");
    }

    struct sockaddr_in dest;
    memcpy(&dest, res->ai_addr, sizeof(dest));
    freeaddrinfo(res);

    unsigned short ident;
    int fd = open_ping_socket(&ident);
    if (fd < 0) return make_error_json(env, "socket_failed");

    int hops = maxHops > 0 ? maxHops : 30;
    int perHop = timeoutMs > 0 ? timeoutMs : 1500;

    size_t cap = 4096;
    char *json = malloc(cap);
    size_t used = (size_t) snprintf(json, cap, "[");

    for (int ttl = 1; ttl <= hops; ttl++) {
        Hop hop;
        int r = probe_one(fd, &dest, ttl, perHop, ident, &hop);
        if (r < 0) break;

        if (used + 256 > cap) {
            cap *= 2;
            json = realloc(json, cap);
        }

        char addrPart[64];
        if (hop.hasAddress) {
            snprintf(addrPart, sizeof(addrPart), "\"%s\"", hop.address);
        } else {
            snprintf(addrPart, sizeof(addrPart), "null");
        }

        char rttPart[32];
        if (hop.hasRtt) {
            snprintf(rttPart, sizeof(rttPart), "%.1f", hop.rttMs);
        } else {
            snprintf(rttPart, sizeof(rttPart), "null");
        }

        used += (size_t) snprintf(
            json + used, cap - used,
            "%s{\"ttl\":%d,\"address\":%s,\"rttMs\":%s,\"isDestination\":%s}",
            ttl == 1 ? "" : ",", ttl, addrPart, rttPart, hop.isDestination ? "true" : "false");

        if (hop.isDestination) break;
    }

    close(fd);

    if (used + 2 > cap) {
        cap += 2;
        json = realloc(json, cap);
    }
    snprintf(json + used, cap - used, "]");

    jstring result = (*env)->NewStringUTF(env, json);
    free(json);
    return result;
}

static JNINativeMethod kMethods[] = {
    {"nativeTrace", "(Ljava/lang/String;II)Ljava/lang/String;", (void *) native_trace},
};

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void) reserved;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    jclass clazz = (*env)->FindClass(env, "dev/netdiag/flutter_netdiag_plus/TracerouteNative");
    if (clazz == NULL) return JNI_ERR;

    if ((*env)->RegisterNatives(env, clazz, kMethods, 1) != JNI_OK) return JNI_ERR;

    return JNI_VERSION_1_6;
}
