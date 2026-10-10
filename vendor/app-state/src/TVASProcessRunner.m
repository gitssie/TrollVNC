#import "TVASRuntime.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
static const NSUInteger PXKeychainOneShotMaximumProcessOutput = 1024 * 1024;
static const NSInteger PXKeychainOneShotExecutionErrorProcess = 21;
static const NSInteger PXKeychainOneShotExecutionErrorTimeout = 22;
static BOOL PXKeychainOneShotExecutionFail(NSError **error,NSInteger code,NSString *reason) {
    if(error)*error=[NSError errorWithDomain:@"TVAppStateProcess" code:code userInfo:@{NSLocalizedDescriptionKey:reason}];return NO;
}
static NSString *PXKeychainOneShotBoundedErrorText(NSString *text) { (void)text;return @""; }
static BOOL PXKeychainOneShotDrainDescriptor(int descriptor,
                                             NSMutableData *data,
                                             NSError * _Nullable * _Nullable error) {
    uint8_t buffer[4096];
    while (YES) {
        ssize_t bytesRead = read(descriptor, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            if (data.length + (NSUInteger)bytesRead > PXKeychainOneShotMaximumProcessOutput) {
                return PXKeychainOneShotExecutionFail(
                    error,
                    PXKeychainOneShotExecutionErrorProcess,
                    @"One-shot helper process produced excessive output");
            }
            [data appendBytes:buffer length:(NSUInteger)bytesRead];
            continue;
        }
        if (bytesRead == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
            return YES;
        }
        if (errno != EINTR) {
            return PXKeychainOneShotExecutionFail(
                error,
                PXKeychainOneShotExecutionErrorProcess,
                @"One-shot helper process output could not be read");
        }
    }
}

@implementation TVASProcessRunner

- (BOOL)runExecutable:(NSString *)executablePath
             arguments:(NSArray<NSString *> *)arguments
               timeout:(NSTimeInterval)timeout
        standardOutput:(NSData * _Nullable * _Nullable)standardOutput
                 error:(NSError * _Nullable * _Nullable)error {
    if (executablePath.length == 0 || !executablePath.isAbsolutePath || timeout <= 0 ||
        access(executablePath.fileSystemRepresentation, X_OK) != 0) {
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"Required one-shot helper executable is unavailable");
    }

    int outputPipe[2] = {-1, -1};
    int errorPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0 || pipe(errorPipe) != 0) {
        if (outputPipe[0] >= 0) close(outputPipe[0]);
        if (outputPipe[1] >= 0) close(outputPipe[1]);
        if (errorPipe[0] >= 0) close(errorPipe[0]);
        if (errorPipe[1] >= 0) close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process pipes could not be created");
    }

    posix_spawn_file_actions_t actions;
    int actionsStatus = posix_spawn_file_actions_init(&actions);
    BOOL actionsInitialized = actionsStatus == 0;
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, errorPipe[0]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
    if (actionsStatus == 0) actionsStatus = posix_spawn_file_actions_addclose(&actions, errorPipe[1]);
    if (actionsStatus != 0) {
        if (actionsInitialized) posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(errorPipe[0]);
        close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process actions could not be prepared");
    }

    NSUInteger argumentCount = arguments.count;
    char **argv = calloc(argumentCount + 2, sizeof(char *));
    BOOL argumentsReady = argv != NULL;
    if (argumentsReady) {
        argv[0] = strdup(executablePath.fileSystemRepresentation);
        argumentsReady = argv[0] != NULL;
    }
    for (NSUInteger index = 0; argumentsReady && index < argumentCount; index++) {
        NSString *argument = arguments[index];
        if (![argument isKindOfClass:[NSString class]]) {
            argumentsReady = NO;
            break;
        }
        argv[index + 1] = strdup(argument.UTF8String);
        argumentsReady = argv[index + 1] != NULL;
    }
    if (!argumentsReady) {
        if (argv) {
            for (NSUInteger index = 0; index < argumentCount + 1; index++) {
                free(argv[index]);
            }
            free(argv);
        }
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(errorPipe[0]);
        close(errorPipe[1]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process arguments could not be prepared");
    }

    pid_t processID = 0;
    int spawnStatus = posix_spawn(&processID,
                                  executablePath.fileSystemRepresentation,
                                  &actions,
                                  NULL,
                                  argv,
                                  environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < argumentCount + 1; index++) {
        free(argv[index]);
    }
    free(argv);
    close(outputPipe[1]);
    close(errorPipe[1]);
    if (spawnStatus != 0) {
        close(outputPipe[0]);
        close(errorPipe[0]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process could not be started");
    }

    int processStatus = 0;
    int outputFlags = fcntl(outputPipe[0], F_GETFL);
    int errorFlags = fcntl(errorPipe[0], F_GETFL);
    if (outputFlags < 0 || errorFlags < 0 ||
        fcntl(outputPipe[0], F_SETFL, outputFlags | O_NONBLOCK) != 0 ||
        fcntl(errorPipe[0], F_SETFL, errorFlags | O_NONBLOCK) != 0) {
        kill(processID, SIGKILL);
        while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
        close(outputPipe[0]);
        close(errorPipe[0]);
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              @"One-shot helper process output could not be configured");
    }
    NSMutableData *outputData = [NSMutableData data];
    NSMutableData *errorData = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL processFinished = NO;
    BOOL outputValid = YES;
    while (!processFinished) {
        outputValid = PXKeychainOneShotDrainDescriptor(outputPipe[0], outputData, error) &&
            PXKeychainOneShotDrainDescriptor(errorPipe[0], errorData, error);
        if (!outputValid) {
            kill(processID, SIGKILL);
        }
        pid_t waitResult = waitpid(processID, &processStatus, WNOHANG);
        if (waitResult == processID) {
            processFinished = YES;
            break;
        }
        if (waitResult < 0 && errno != EINTR) {
            kill(processID, SIGKILL);
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorProcess,
                                                  @"One-shot helper process could not be observed");
        }
        if (!outputValid) {
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return NO;
        }
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            kill(processID, SIGKILL);
            while (waitpid(processID, &processStatus, 0) < 0 && errno == EINTR) {}
            close(outputPipe[0]);
            close(errorPipe[0]);
            return PXKeychainOneShotExecutionFail(error,
                                                  PXKeychainOneShotExecutionErrorTimeout,
                                                  @"One-shot helper process timed out");
        }
        usleep(10 * 1000);
    }
    BOOL finalOutputValid = PXKeychainOneShotDrainDescriptor(outputPipe[0], outputData, error) &&
        PXKeychainOneShotDrainDescriptor(errorPipe[0], errorData, error);
    close(outputPipe[0]);
    close(errorPipe[0]);
    if (!finalOutputValid) {
        return NO;
    }
    if (!WIFEXITED(processStatus) || WEXITSTATUS(processStatus) != 0) {
        NSString *reportedError = [[NSString alloc] initWithData:errorData
                                                        encoding:NSUTF8StringEncoding];
        NSString *boundedError = PXKeychainOneShotBoundedErrorText(reportedError);
        NSString *reason = boundedError.length > 0
            ? [NSString stringWithFormat:@"One-shot helper process failed: %@",
                boundedError]
            : @"One-shot helper process failed";
        return PXKeychainOneShotExecutionFail(error,
                                              PXKeychainOneShotExecutionErrorProcess,
                                              reason);
    }
    if (standardOutput) {
        *standardOutput = [outputData copy];
    }
    return YES;
}

@end