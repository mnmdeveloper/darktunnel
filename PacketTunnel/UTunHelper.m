#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>

// iOS SDKs used by PacketTunnel do not expose <sys/kern_control.h>.
// Identify the already-created utun socket via its interface-name socket option.
#ifndef DT_SYSPROTO_CONTROL
#define DT_SYSPROTO_CONTROL 2
#endif

#ifndef DT_UTUN_OPT_IFNAME
#define DT_UTUN_OPT_IFNAME 2
#endif

#ifndef IFNAMSIZ
#define IFNAMSIZ 16
#endif

int32_t dt_find_utun_fd(void) {
    for (int32_t fd = 0; fd <= 1024; fd++) {
        char ifname[IFNAMSIZ] = {0};
        socklen_t ifnameLength = (socklen_t)sizeof(ifname);

        if (getsockopt(fd,
                       DT_SYSPROTO_CONTROL,
                       DT_UTUN_OPT_IFNAME,
                       ifname,
                       &ifnameLength) != 0) {
            continue;
        }

        if (strncmp(ifname, "utun", 4) == 0) {
            return fd;
        }
    }

    return -1;
}
