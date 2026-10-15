#import "TVKaringNative.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

NSDictionary *TVKaringReadDocument(NSString *container, NSString *filename) {
    if (![@[@"service_core.json", @"karing_subscribe.json", @"karing_subscribe_use.json", @"karing_setting.json"] containsObject:filename])
        return @{@"error":@"invalid_document"};
    NSString *path = [container stringByAppendingPathComponent:filename];
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (descriptor < 0) return @{@"error":@"document_unavailable"};
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0 || !S_ISREG(attributes.st_mode) || attributes.st_size > 8 * 1024 * 1024) {
        close(descriptor); return @{@"error":@"document_unavailable"};
    }
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[16384];
    BOOL valid = YES;
    for (;;) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || data.length + (NSUInteger)count > 8 * 1024 * 1024) { valid = NO; break; }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(descriptor);
    if (!valid) return @{@"error":@"document_unavailable"};
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSArray.class])
        return @{@"error":@"invalid_document_json"};
    // Preserve the complete document, including fields unknown to this module.
    return @{@"data":json};
}
