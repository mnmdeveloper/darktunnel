#ifndef DarkTunnel_BridgeHeader_h
#define DarkTunnel_BridgeHeader_h

#include <stdint.h>
#include <sys/types.h>
#include "wireguard_turn.h"
#include "AmneziaWGBridge.h"

/*
 * Apple stopped shipping <sys/kern_control.h> to iOS SDK consumers.
 * These are the stable ABI definitions used by WireGuard's iOS adapter
 * to locate the NetworkExtension utun socket without importing that header.
 */
#ifndef CTLIOCGINFO
#define CTLIOCGINFO 0xc0644e03UL
#endif

#ifndef DARKTUNNEL_CTL_INFO_DEFINED
#define DARKTUNNEL_CTL_INFO_DEFINED 1
struct ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};
#endif

#ifndef DARKTUNNEL_SOCKADDR_CTL_DEFINED
#define DARKTUNNEL_SOCKADDR_CTL_DEFINED 1
struct sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};
#endif

#ifdef __cplusplus
extern "C" {
#endif

int32_t dt_find_utun_fd(void);

#ifdef __cplusplus
}
#endif

#endif
