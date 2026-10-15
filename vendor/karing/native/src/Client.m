#import "TVKaringNative.h"
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
extern char **environ;

@implementation TVKaringHelperClient {
    NSString *_executable;
}
- (instancetype)initWithExecutable:(NSString *)executable {
    if ((self = [super init])) _executable = [executable copy];
    return self;
}
- (NSDictionary *)request:(NSString *)operation {
    if (![@[@"config", @"profiles", @"status", @"reload"] containsObject:operation]) return @{@"error":@"invalid_operation"};
    BOOL mutation = [operation isEqual:@"reload"];
    if (!_executable.isAbsolutePath || access(_executable.fileSystemRepresentation, X_OK) != 0)
        return @{@"error":@"helper_unavailable", @"outcome":@"not_sent"};
    int descriptors[2];
    if (pipe(descriptors) != 0) return @{@"error":@"helper_pipe_failed", @"outcome":@"not_sent"};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int code = posix_spawn_file_actions_init(&actions);
    BOOL hasActions = code == 0, hasAttributes = NO;
    if (!code) { code = posix_spawnattr_init(&attributes); hasAttributes = code == 0; }
    if (!code) code = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!code) code = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    if (!code) code = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!code) code = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    char *arguments[] = {(char *)_executable.fileSystemRepresentation, (char *)operation.UTF8String, NULL};
    pid_t pid = 0;
    if (!code) code = posix_spawn(&pid, _executable.fileSystemRepresentation, &actions, &attributes, arguments, environ);
    if (hasActions) posix_spawn_file_actions_destroy(&actions);
    if (hasAttributes) posix_spawnattr_destroy(&attributes);
    close(descriptors[1]);
    if (code) { close(descriptors[0]); return @{@"error":@"helper_spawn_failed", @"outcome":@"not_sent"}; }
    int flags = fcntl(descriptors[0], F_GETFL);
    BOOL failed = flags < 0 || fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != 0;
    BOOL finished = NO;
    int status = 0;
    NSMutableData *output = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 50;
    while (!failed) {
        unsigned char buffer[16384];
        ssize_t count;
        while ((count = read(descriptors[0], buffer, sizeof(buffer))) > 0) {
            if (output.length + (NSUInteger)count > 32 * 1024 * 1024) { failed = YES; break; }
            [output appendBytes:buffer length:(NSUInteger)count];
            if (NSProcessInfo.processInfo.systemUptime >= deadline) { failed = YES; break; }
        }
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) failed = YES;
        if (finished || failed) break;
        pid_t observed = waitpid(pid, &status, WNOHANG);
        if (observed == pid) { finished = YES; continue; } // Final drain after exit.
        if (observed < 0 && errno != EINTR) { failed = YES; break; }
        if (NSProcessInfo.processInfo.systemUptime >= deadline) { failed = YES; break; }
        usleep(10000);
    }
    if (!finished) {
        kill(pid, SIGKILL);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
    close(descriptors[0]);
    if (failed || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return @{@"error":@"helper_execution_failed", @"outcome":mutation ? @"unknown" : @"failed"};
    id value = [NSJSONSerialization JSONObjectWithData:output options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return @{@"error":@"invalid_helper_response", @"outcome":mutation ? @"unknown" : @"failed"};
    return value;
}
@end
