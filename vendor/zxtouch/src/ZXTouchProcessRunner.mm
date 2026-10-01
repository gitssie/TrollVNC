// SPDX-License-Identifier: GPL-2.0-only
#import "ZXTouchProcessRunner.h"
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <cstring>
#include <cmath>
#include <mach-o/dyld.h>

@interface ZXProcess : NSObject
@property pid_t pid;
@property BOOL cancelled;
@end
@implementation ZXProcess
@end

static BOOL ZXProcessError(NSError **error, NSString *message, int code = EINVAL) {
    if (error) *error = [NSError errorWithDomain:@"TrollVNC.ZXTouch.Process" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@implementation ZXTouchProcessRunner {
    NSString *_root;
    NSString *_modulePath;
    NSString *_logPath;
    NSMutableSet<ZXProcess *> *_processes;
    ZXProcess *_script;
    BOOL _stopped;
}
// argv[0] may be only "trollvncserver", or an arbitrary caller-provided name.
// dyld identifies the executable independently of the launcher's argv.
+ (NSDictionary<NSString *, NSString *> *)runtimePaths {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> buffer(size);
    NSString *executable = _NSGetExecutablePath(buffer.data(), &size) == 0 ?
        [NSFileManager.defaultManager stringWithFileSystemRepresentation:buffer.data() length:strlen(buffer.data())] : nil;
    if (!executable.length) executable = NSBundle.mainBundle.executablePath;
    if (!executable.isAbsolutePath) executable = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:executable ?: @""];
    executable = executable.stringByResolvingSymlinksInPath;
    NSRange prefix = [executable rangeOfString:@"/usr/bin/" options:NSBackwardsSearch];
    NSString *root = prefix.location == NSNotFound ? @"" : [executable substringToIndex:prefix.location];
    NSString *modules = prefix.location == NSNotFound ? [executable.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"python"] :
        [root stringByAppendingString:@"/usr/share/trollvnc/python"];
    return @{@"executable":executable, @"root":root, @"modules":modules};
}
- (instancetype)initWithRuntimeRoot:(NSString *)root modulePath:(NSString *)modulePath logPath:(NSString *)logPath {
    if ((self = [super init])) {
        _root = [root copy]; _modulePath = [modulePath copy]; _logPath = [logPath copy];
        _processes = [NSMutableSet set];
        self.environment = @{};
    }
    return self;
}
- (NSString *)executable:(NSArray<NSString *> *)names {
    NSMutableArray *roots = [NSMutableArray array];
    if (_root.length) [roots addObject:_root];
    [roots addObjectsFromArray:@[@"/var/jb", @""]];
    for (NSString *root in roots) for (NSString *name in names) {
        NSString *path = [root stringByAppendingString:name];
        if (access(path.fileSystemRepresentation, X_OK) == 0) return path;
    }
    return nil;
}
- (ZXProcess *)spawn:(NSString *)program arguments:(NSArray<NSString *> *)arguments
                 cwd:(NSString *)cwd script:(BOOL)script error:(NSError **)error {
    if (!program) { ZXProcessError(error, @"Required interpreter is not installed", ENOENT); return nil; }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:_logPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    // spawn copies argv/envp before returning. No shell interpolation is used
    // for script paths, interpreter paths or working directories.
    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:program];
    [argvStrings addObjectsFromArray:arguments];
    std::vector<char *> argv;
    for (NSString *arg in argvStrings) argv.push_back((char *)arg.UTF8String);
    argv.push_back(nullptr);
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment addEntriesFromDictionary:self.environment];
    environment[@"PYTHONDONTWRITEBYTECODE"] = @"1";
    if (_modulePath.length) {
        NSString *existing = environment[@"PYTHONPATH"];
        environment[@"PYTHONPATH"] = existing.length ? [_modulePath stringByAppendingFormat:@":%@", existing] : _modulePath;
    }
    NSMutableArray<NSString *> *environmentStrings = [NSMutableArray array];
    for (NSString *key in environment) [environmentStrings addObject:[NSString stringWithFormat:@"%@=%@", key, environment[key]]];
    std::vector<char *> envp;
    for (NSString *entry in environmentStrings) envp.push_back((char *)entry.UTF8String);
    envp.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attributes);
    int result = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, _logPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    // iOS has no spawn chdir action; the Python launcher changes only its own cwd.
    (void)cwd;
    if (!result) result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!result) result = posix_spawnattr_setpgroup(&attributes, 0);
    ZXProcess *process = [ZXProcess new];
    @synchronized(_processes) {
        if (_stopped || (script && _script)) result = EBUSY;
        pid_t pid = 0;
        if (!result) result = posix_spawn(&pid, program.fileSystemRepresentation, &actions, &attributes, argv.data(), envp.data());
        process.pid = pid;
        if (!result) {
            [_processes addObject:process];
            if (script) _script = process;
        }
    }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (result) { ZXProcessError(error, [NSString stringWithFormat:@"Cannot start process: %s", strerror(result)], result); return nil; }
    return process;
}
- (BOOL)wait:(ZXProcess *)process cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    int status = 0;
    for (;;) {
        BOOL cancel = cancelled && cancelled();
        int failure = 0;
        pid_t result;
        @synchronized(_processes) {
            if (cancel || _stopped || process.cancelled) {
                process.cancelled = YES;
                // PID is still owned until waitpid reaps it under this lock.
                kill(-process.pid, SIGKILL);
            }
            // Keep the exited leader unreaped as a PID/group ownership anchor
            // until remaining descendants are killed. Reaping first would both
            // lose those descendants and permit this group ID to be reused.
            siginfo_t info = {};
            int observed = waitid(P_PID, process.pid, &info, WEXITED | WNOHANG | WNOWAIT);
            if (observed < 0) { result = -1; failure = errno; }
            else if (info.si_pid == process.pid) {
                kill(-process.pid, SIGKILL);
                result = waitpid(process.pid, &status, WNOHANG);
                if (result < 0) failure = errno;
            } else result = 0;
            if (result == process.pid || (result < 0 && failure != EINTR)) {
                [_processes removeObject:process];
                if (_script == process) _script = nil;
            }
        }
        if (result == process.pid) break;
        if (result < 0 && failure != EINTR) return ZXProcessError(error, @"Unable to wait for child process", failure);
        usleep(10000);
    }
    if (process.cancelled) return ZXProcessError(error, @"Command was cancelled", ECANCELED);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return ZXProcessError(error, [NSString stringWithFormat:@"Command exited with status %d",
            WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)]);
    return YES;
}
- (BOOL)runShell:(NSString *)command cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    ZXProcess *process = [self spawn:[self executable:@[@"/bin/sh", @"/usr/bin/sh"]]
        arguments:@[@"-c", command] cwd:nil script:NO error:error];
    return process && [self wait:process cancelled:cancelled error:error];
}
- (BOOL)startScript:(NSString *)path error:(NSError **)error {
    if (!path.isAbsolutePath) return ZXProcessError(error, @"Script path must be absolute");
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory]) return ZXProcessError(error, @"Script does not exist", ENOENT);
    NSString *entry = path;
    if (directory) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"info.plist"]];
        NSString *name = [info[@"Entry"] isKindOfClass:NSString.class] ? info[@"Entry"] : nil;
        if (!name.length || name.isAbsolutePath) return ZXProcessError(error, @"Script bundle has no valid Entry");
        entry = [[path stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
        NSString *base = [[path stringByResolvingSymlinksInPath] stringByAppendingString:@"/"];
        if (![entry hasPrefix:base]) return ZXProcessError(error, @"Script Entry leaves its bundle directory");
    }
    if (![entry.pathExtension.lowercaseString isEqualToString:@"py"])
        return ZXProcessError(error, @"Only Python scripts are supported; recorded raw playback is excluded");
    if (![NSFileManager.defaultManager isReadableFileAtPath:entry]) return ZXProcessError(error, @"Cannot read script", ENOENT);
    NSString *python = [self executable:@[@"/usr/bin/python3.13", @"/usr/bin/python3.12", @"/usr/bin/python3.11",
        @"/usr/bin/python3.10", @"/usr/bin/python3.9", @"/usr/bin/python3"]];
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/ZXTouch/config/tweak/script_play_settings.plist"];
    NSDictionary *configs = [settings[@"individual_configs"] isKindOfClass:NSDictionary.class] ? settings[@"individual_configs"] : nil;
    NSDictionary *config = [configs[path] isKindOfClass:NSDictionary.class] ? configs[path] : nil;
    NSInteger repeats = MAX(0, MIN(100000, [config[@"repeat_times"] integerValue]));
    double interval = [config[@"interval"] doubleValue];
    if (!std::isfinite(interval) || interval < 0 || interval > 3600) return ZXProcessError(error, @"Invalid script repeat interval");
    NSString *launcher = @"import os,runpy,sys,time\np=sys.argv[1];n=int(sys.argv[2]);delay=float(sys.argv[3]);os.chdir(os.path.dirname(p));sys.argv=[p]\nfor i in range(n+1):\n if i: time.sleep(delay)\n runpy.run_path(p,run_name='__main__')\n";
    ZXProcess *process = [self spawn:python arguments:@[@"-u", @"-c", launcher, entry, @(repeats).stringValue, @(interval).stringValue]
        cwd:nil script:YES error:error];
    if (!process) return NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { [self wait:process cancelled:^BOOL { return NO; } error:nil]; }
    });
    return YES;
}
- (BOOL)stopScript:(NSError **)error {
    @synchronized(_processes) {
        if (!_script) return ZXProcessError(error, @"No script is running");
        _script.cancelled = YES;
        kill(-_script.pid, SIGKILL);
        return YES;
    }
}
- (BOOL)isScriptRunning {
    @synchronized(_processes) { return _script != nil; }
}
- (void)stop {
    @synchronized(_processes) {
        _stopped = YES;
        for (ZXProcess *process in _processes) { process.cancelled = YES; kill(-process.pid, SIGKILL); }
    }
}
@end
