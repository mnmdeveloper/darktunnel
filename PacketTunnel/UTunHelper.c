#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <net/if.h>

int32_t dt_find_utun_fd(void) {
    char name[IFNAMSIZ];
    for (int fd = 0; fd <= 1024; ++fd) {
        memset(name, 0, sizeof(name));
        socklen_t length = (socklen_t)sizeof(name);
        if (getsockopt(fd, SYSPROTO_CONTROL, 2, name, &length) == 0 &&
            strncmp(name, "utun", 4) == 0) {
            return (int32_t)fd;
        }
    }
    return -1;
}
