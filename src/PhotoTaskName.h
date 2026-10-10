#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <string.h>

// The UUID is stable across retries; only the upload attempt nonce changes.
// Accept both legacy UUID--name and UUID-16hex--name staging names.
static inline NSString *tvPhotoUploadOriginalName(NSString *name, NSString **taskIdentifier) {
    NSString *prefix = @"rv-upload-";
    NSUInteger suffixAt = prefix.length + 36;
    if (![name hasPrefix:prefix] || name.length <= suffixAt + 2 ||
        [name containsString:@"/"] || [name containsString:@"\\"]) return nil;
    NSString *identifier = [name substringWithRange:NSMakeRange(prefix.length, 36)];
    if (![[NSUUID alloc] initWithUUIDString:identifier]) return nil;
    NSUInteger originalAt;
    if ([[name substringWithRange:NSMakeRange(suffixAt, 2)] isEqualToString:@"--"]) {
        originalAt = suffixAt + 2;
    } else {
        if (name.length <= suffixAt + 19 || [name characterAtIndex:suffixAt] != '-' ||
            ![[name substringWithRange:NSMakeRange(suffixAt + 17, 2)] isEqualToString:@"--"]) return nil;
        NSString *nonce = [name substringWithRange:NSMakeRange(suffixAt + 1, 16)];
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        if ([nonce rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
        originalAt = suffixAt + 19;
    }
    NSString *original = [name substringFromIndex:originalAt];
    if (!original.length || [original isEqualToString:@"."] || [original isEqualToString:@".."]) return nil;
    if (taskIdentifier) *taskIdentifier = identifier;
    return original;
}

static inline BOOL tvPhotoGeneratedNameCanCleanup(NSString *name) {
    if (!name || [name containsString:@"/"] || [name containsString:@"\\"] ||
        strlen(name.fileSystemRepresentation) > NAME_MAX ||
        ![@[@"png", @"jpg", @"jpeg", @"heic", @"heif"] containsObject:name.pathExtension.lowercaseString]) return NO;
    if (tvPhotoUploadOriginalName(name, NULL)) return YES;
    NSUInteger suffixAt = 10 + 36;
    if (![name hasPrefix:@"rv-export-"] || name.length <= suffixAt ||
        ![[NSUUID alloc] initWithUUIDString:[name substringWithRange:NSMakeRange(10, 36)]]) return NO;
    NSString *suffix = [name substringFromIndex:suffixAt];
    return [suffix hasPrefix:@"."] || ([suffix hasPrefix:@"--"] && suffix.length > 2);
}
