#ifndef DarkTunnel_AmneziaWGBridge_h
#define DarkTunnel_AmneziaWGBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void awgSetLogger(uintptr_t context, uintptr_t loggerFn);
int32_t awgTurnOn(const char *settings, int32_t tunFd);
void awgTurnOff(int32_t tunnelHandle);
int64_t awgSetConfig(int32_t tunnelHandle, const char *settings);
char *awgGetConfig(int32_t tunnelHandle);
void awgBumpSockets(int32_t tunnelHandle);
void awgDisableSomeRoamingForBrokenMobileSemantics(int32_t tunnelHandle);
char *awgVersion(void);

#ifdef __cplusplus
}
#endif

#endif
