#ifndef DarkTunnel_BridgeHeader_h
#define DarkTunnel_BridgeHeader_h

#include "wireguard_turn.h"
#include "AmneziaWGBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

int32_t dt_find_utun_fd(void);

#ifdef __cplusplus
}
#endif

#endif
