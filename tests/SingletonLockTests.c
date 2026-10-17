#include "SingletonLock.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    char base[] = "/tmp/tvnc-lock-test.XXXXXX";
    assert(mkdtemp(base));
    char dir[256], target[256], path[256];
    snprintf(dir, sizeof(dir), "%s/run", base);
    snprintf(target, sizeof(target), "%s/target", base);
    snprintf(path, sizeof(path), "%s/run/lock", base);
    int fd = open(target, O_CREAT | O_WRONLY, 0600); assert(fd >= 0);
    assert(write(fd, "safe", 4) == 4); close(fd);
    assert(symlink(base, dir) == 0);
    assert(tvOpenSingletonLockIn(dir, "lock") < 0); unlink(dir);
    assert(mkdir(dir, 0700) == 0);
    assert(symlink(target, path) == 0);
    assert(tvOpenSingletonLockIn(dir, "lock") < 0); unlink(path);
    assert(link(target, path) == 0);
    assert(tvOpenSingletonLockIn(dir, "lock") < 0); unlink(path);
    fd = tvOpenSingletonLockIn(dir, "lock"); assert(fd >= 0); close(fd);
    assert(chmod(dir, 0777) == 0);
    assert(tvOpenSingletonLockIn(dir, "lock") < 0);
    fd = open(target, O_RDONLY); char bytes[5] = {0}; assert(read(fd, bytes, 4) == 4);
    close(fd); assert(strcmp(bytes, "safe") == 0);
    unlink(path); unlink(target); rmdir(dir); rmdir(base);
    puts("PASS: private singleton locks reject directory/file symlinks, hardlinks and unsafe modes");
}
