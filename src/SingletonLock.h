#pragma once
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

static inline int tvOpenSingletonLockIn(const char *directory, const char *name) {
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return -1;
    int parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0) return -1;
    struct stat st;
    if (fstat(parent, &st) || st.st_uid != geteuid() || (st.st_mode & 0077)) {
        close(parent); errno = EPERM; return -1;
    }
    int fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(parent);
    if (fd < 0) return -1;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid()
        || st.st_nlink != 1 || (st.st_mode & 0077)) {
        close(fd); errno = EPERM; return -1;
    }
    return fd;
}
static inline int tvOpenSingletonLock(const char *name) {
    char directory[128];
    snprintf(directory, sizeof(directory), "/tmp/com.82flex.trollvnc.runtime.%u", (unsigned)geteuid());
    return tvOpenSingletonLockIn(directory, name);
}
