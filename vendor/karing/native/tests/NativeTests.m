#import "TVKaringNative.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
static void Check(BOOL value, const char *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        Check([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil], "create fixture");
        @try {
            NSString *document = [root stringByAppendingPathComponent:@"service_core.json"];
            [@"{\"outbounds\":[{\"tag\":\"a\",\"future\":{\"unknown\":true}}],\"route\":{\"final\":\"a\"}}" writeToFile:document atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary *result = TVKaringReadDocument(root, @"service_core.json");
            Check([result[@"data"][@"outbounds"][0][@"future"][@"unknown"] boolValue], "preserve unknown fields");
            Check(TVKaringReadDocument(root, @"../service_core.json")[@"error"] != nil, "reject filename traversal");
            Check(TVKaringReadDocument(root, @"karing_setting.json")[@"error"] != nil, "missing file");
            [@"broken" writeToFile:document atomically:YES encoding:NSUTF8StringEncoding error:nil];
            Check([TVKaringReadDocument(root, @"service_core.json")[@"error"] isEqual:@"invalid_document_json"], "malformed JSON");
            [files removeItemAtPath:document error:nil];
            [files createSymbolicLinkAtPath:document withDestinationPath:@"/etc/passwd" error:nil];
            Check(TVKaringReadDocument(root, @"service_core.json")[@"error"] != nil, "reject document symlink");
            [files removeItemAtPath:document error:nil];
            [NSMutableData.data writeToFile:document atomically:YES];
            int fd = open(document.fileSystemRepresentation, O_WRONLY);
            Check(fd >= 0 && ftruncate(fd, 8 * 1024 * 1024 + 1) == 0, "large fixture"); close(fd);
            Check([TVKaringReadDocument(root, @"service_core.json")[@"error"] isEqual:@"document_unavailable"], "bound document size");
            NSString *helper = [root stringByAppendingPathComponent:@"helper"];
            [@"#!/bin/sh\nprintf '{\"data\":{\"future\":42},\"operation\":\"%s\"}\\n' \"$1\"\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(helper.fileSystemRepresentation, 0700);
            TVKaringHelperClient *client = [[TVKaringHelperClient alloc] initWithExecutable:helper];
            result = [client request:@"status"];
            Check([result[@"data"][@"future"] intValue] == 42 && [result[@"operation"] isEqual:@"status"], "argv / return passthrough");
            Check([[client request:@"status; touch /tmp/forbidden"][@"error"] isEqual:@"invalid_operation"], "reject arbitrary operations");
            [@"#!/bin/sh\nprintf 'not-json'\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(helper.fileSystemRepresentation, 0700);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"unknown"], "malformed mutation response remains unknown");
            [@"#!/bin/sh\nexit 42\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(helper.fileSystemRepresentation, 0700);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"unknown"], "failed helper cannot claim mutation failed safely");
            chmod(helper.fileSystemRepresentation, 0600);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"not_sent"], "missing executable not sent");
            puts("PASS native document and helper transport regressions");
        } @finally { [files removeItemAtPath:root error:nil]; }
    }
    return 0;
}
