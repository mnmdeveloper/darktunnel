#ifndef DarkTunnel_AmneziaWGBridge_h
#define DarkTunnel_AmneziaWGBridge_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// amneziawg-apple's WireGuardKitGo bridge exports the standard WireGuard
// C symbols (wg*). Keep the awg* names used by DarkTunnel as compatibility
// aliases so PacketTunnel does not need to know about the vendor naming.
void wgSetLogger(void *context, void (*loggerFn)(void *context, int level, const char *msg));
int wgTurnOn(const char *settings, int32_t tunFd);
void wgTurnOff(int tunnelHandle);
int64_t wgSetConfig(int tunnelHandle, const char *settings);
void wgBumpSockets(int tunnelHandle);
void wgDisableSomeRoamingForBrokenMobileSemantics(int tunnelHandle);
const char *wgVersion(void);

#ifdef __cplusplus
}
#endif

#define awgSetLogger wgSetLogger
#define awgTurnOn wgTurnOn
#define awgTurnOff wgTurnOff
#define awgSetConfig wgSetConfig
#define awgBumpSockets wgBumpSockets
#define awgDisableSomeRoamingForBrokenMobileSemantics wgDisableSomeRoamingForBrokenMobileSemantics
#define awgVersion wgVersion

#endif
