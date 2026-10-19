/* This program requires CAP_SYS_ADMIN */

#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/capability.h>

/* Intentionally empty until a service needs to run commands in its netns.
   To allow one, add its netns name here, e.g. "nb-bitcoind".
   Netns names are `nb-<service>` (see modules/netns-isolation.nix).
   With no entries, the array has length 0 and every netns is rejected. */
static char *allowed_netns[] = { };

int is_netns_allowed(char *netns) {
    int n_allowed_netns = sizeof(allowed_netns) / sizeof(allowed_netns[0]);
    for (int i = 0; i < n_allowed_netns; i++) {
        if (strcmp(allowed_netns[i], netns) == 0) {
            return 1;
        }
    }
    return 0;
}

void print_capabilities() {
    cap_t caps = cap_get_proc();
    printf("Capabilities: %s\n", cap_to_text(caps, NULL));
    cap_free(caps);
}

int drop_capabilities() {
    cap_t caps = cap_get_proc();
    if (caps == NULL) return -1;
    if (cap_clear(caps) < 0) { cap_free(caps); return -1; }
    int rc = cap_set_proc(caps);
    cap_free(caps);
    return rc;
}

int main(int argc, char **argv) {
    char netns_path[256];

    if (argc < 3) {
        fprintf(stderr, "usage: %s <netns> <absolute command path> [args...]\n", argv[0]);
        return 1;
    }

    /* Require an absolute path so PATH cannot redirect the exec target.
       The caller's environment is otherwise inherited. Only the allowed
       user may run this wrapper: by default the operator, a regular user
       with group access to the services. */
    if (argv[2][0] != '/') {
        fprintf(stderr, "command must be an absolute path.\n");
        return 1;
    }

    if (!is_netns_allowed(argv[1])) {
        fprintf(stderr, "%s is not an allowed netns.\n", argv[1]);
        return 1;
    }

    int len = snprintf(netns_path, sizeof(netns_path), "/var/run/netns/%s", argv[1]);
    if (len < 0 || (size_t)len >= sizeof(netns_path)) {
        fprintf(stderr, "Path length exceeded for netns %s.\n", argv[1]);
        return 1;
    }

    int fd = open(netns_path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Failed opening netns %s: %d, %s \n", netns_path, errno, strerror(errno));
        return 1;
    }

    if (setns(fd, CLONE_NEWNET) < 0) {
        fprintf(stderr, "Failed setns %d, %s \n", errno, strerror(errno));
        close(fd);
        return 1;
    }
    close(fd);

    /* Drop capabilities. Never run the command with CAP_SYS_ADMIN still held. */
    #ifdef DEBUG
    print_capabilities();
    #endif
    if (drop_capabilities() < 0) {
        fprintf(stderr, "Failed to drop capabilities: %d, %s \n", errno, strerror(errno));
        return 1;
    }
    #ifdef DEBUG
    print_capabilities();
    #endif

    execv(argv[2], &argv[2]);
    /* Only reached on exec failure */
    fprintf(stderr, "Failed to exec %s: %d, %s \n", argv[2], errno, strerror(errno));
    return 1;
}
