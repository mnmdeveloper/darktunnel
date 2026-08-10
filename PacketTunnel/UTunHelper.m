#import <Foundation/Foundation.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/types.h>

int32_t dt_find_utun_fd(void) {
    struct ctl_info ctlInfo = {0};
    strlcpy(ctlInfo.ctl_name, "com.apple.net.utun_control", sizeof(ctlInfo.ctl_name));

    for (int32_t fd = 0; fd <= 1024; fd++) {
        struct sockaddr_ctl addr = {0};
        socklen_t length = (socklen_t)sizeof(addr);

        if (getpeername(fd, (struct sockaddr *)&addr, &length) != 0) {
            continue;
        }

        if (addr.sc_family != AF_SYSTEM || addr.ss_sysaddr != AF_SYS_CONTROL) {
            continue;
        }

        if (ctlInfo.ctl_id == 0) {
            if (ioctl(fd, CTLIOCGINFO, &ctlInfo) != 0) {
                continue;
            }
        }

        if (addr.sc_id == ctlInfo.ctl_id) {
            return fd;
        }
    }

    return -1;
}
