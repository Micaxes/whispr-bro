// net-tripwire.c — runtime offline tripwire (spec §11.7, §12).
//
// A tiny DYLD-interpose library. Injected via DYLD_INSERT_LIBRARIES into a
// debug/bench run (see verify-offline-capture.sh), it replaces connect() and
// aborts LOUDLY the instant the process tries to open an outbound network
// connection — turning "we believe it's offline" into "it provably cannot
// reach the network without crashing on the spot."
//
// It gates every way a process can start talking to a remote host: connect()
// (TCP), connectx() (Network.framework / MPTCP), and sendto()/sendmsg() to an
// explicit remote address (unconnected UDP — QUIC/HTTP3, DNS, telemetry). A
// send on an already-connected socket is allowed here because its connect() was
// already gated.
//
// Loopback (127.0.0.0/8, ::1) and AF_UNIX are allowed: macOS frameworks talk
// to local daemons over those and it is not network egress. Anything else —
// any real IPv4/IPv6 peer — is a violation of the offline invariant and hard-
// aborts so it can never pass a test silently.
//
// Build:  cc -dynamiclib -o net-tripwire.dylib net-tripwire.c
// Run:    DYLD_INSERT_LIBRARIES=/abs/net-tripwire.dylib <our-own-build-product>
// (Only works on our own unsigned build products; SIP/hardened-runtime binaries
//  strip DYLD_INSERT_LIBRARIES — which is why we point it at whispr-bench.)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>

typedef struct interpose_s {
    const void *replacement;
    const void *original;
} interpose_t;

// 1 if the destination is loopback / local (allowed), 0 if it is network egress.
// `len` is the caller-provided address length; a too-short address for the
// family is treated as local (allow) so we never read past the buffer — the
// real syscall will reject a malformed address anyway.
static int tw_is_local(const struct sockaddr *addr, socklen_t len) {
    if (!addr) return 1;                       // no address → let the real call handle it
    switch (addr->sa_family) {
        case AF_UNIX: return 1;                // local IPC
        case AF_INET: {
            if (len < (socklen_t)sizeof(struct sockaddr_in)) return 1;
            const struct sockaddr_in *a = (const struct sockaddr_in *)addr;
            uint32_t h = ntohl(a->sin_addr.s_addr);
            return (h >> 24) == 127;           // 127.0.0.0/8
        }
        case AF_INET6: {
            if (len < (socklen_t)sizeof(struct sockaddr_in6)) return 1;
            const struct sockaddr_in6 *a6 = (const struct sockaddr_in6 *)addr;
            return IN6_IS_ADDR_LOOPBACK(&a6->sin6_addr) ? 1 : 0;
        }
        default: return 1;                     // AF_SYSTEM et al. — not IP egress
    }
}

static void tw_abort(const char *call, const struct sockaddr *addr) {
    char ip[INET6_ADDRSTRLEN] = "?";
    if (addr && addr->sa_family == AF_INET)
        inet_ntop(AF_INET, &((const struct sockaddr_in *)addr)->sin_addr, ip, sizeof ip);
    else if (addr && addr->sa_family == AF_INET6)
        inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)addr)->sin6_addr, ip, sizeof ip);
    fprintf(stderr,
        "\n"
        "*** whispr-bro NET TRIPWIRE ***\n"
        "*** outbound %s to %s — the offline invariant was violated.\n"
        "*** aborting so this can never pass silently.\n\n", call, ip);
    fflush(stderr);
    abort();
}

// Interpose does not redirect the interposing image's OWN references, so each
// replacement below reaches the real libc function.

static int tw_connect(int s, const struct sockaddr *addr, socklen_t len) {
    if (!tw_is_local(addr, len)) tw_abort("connect()", addr);
    return connect(s, addr, len);
}

static int tw_connectx(int s, const sa_endpoints_t *eps, sae_associd_t aid,
                       unsigned int flags, const struct iovec *iov,
                       unsigned int iovcnt, size_t *len, sae_connid_t *cid) {
    if (eps && eps->sae_dstaddr && !tw_is_local(eps->sae_dstaddr, eps->sae_dstaddrlen))
        tw_abort("connectx()", eps->sae_dstaddr);
    return connectx(s, eps, aid, flags, iov, iovcnt, len, cid);
}

static ssize_t tw_sendto(int s, const void *buf, size_t n, int flags,
                         const struct sockaddr *addr, socklen_t addrlen) {
    // A non-null explicit destination is a datagram to a specific peer; NULL
    // means the socket is already connected (its connect() was gated).
    if (addr && !tw_is_local(addr, addrlen)) tw_abort("sendto()", addr);
    return sendto(s, buf, n, flags, addr, addrlen);
}

static ssize_t tw_sendmsg(int s, const struct msghdr *msg, int flags) {
    if (msg && msg->msg_name &&
        !tw_is_local((const struct sockaddr *)msg->msg_name, msg->msg_namelen))
        tw_abort("sendmsg()", (const struct sockaddr *)msg->msg_name);
    return sendmsg(s, msg, flags);
}

#define TW_INTERPOSE(repl, orig) \
    __attribute__((used)) static const interpose_t tw_ip_##orig \
        __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig }

TW_INTERPOSE(tw_connect, connect);
TW_INTERPOSE(tw_connectx, connectx);
TW_INTERPOSE(tw_sendto, sendto);
TW_INTERPOSE(tw_sendmsg, sendmsg);
