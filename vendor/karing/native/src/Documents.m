#import "TVKaringNative.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static BOOL AllowedDocument(NSString *filename) {
    return [@[@"service_core.json", @"karing_subscribe.json", @"karing_subscribe_use.json", @"karing_setting.json"] containsObject:filename];
}

NSDictionary *TVKaringReadDocument(NSString *container, NSString *filename) {
    if (!AllowedDocument(filename))
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

BOOL TVKaringWriteDocument(NSString *container, NSString *filename, id document) {
    if (!AllowedDocument(filename)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:0 error:nil];
    if (!data || data.length > 8 * 1024 * 1024) return NO;
    NSString *path = [container stringByAppendingPathComponent:filename];
    int original = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info;
    if (original < 0) return NO;
    BOOL valid = fstat(original, &info) == 0 && S_ISREG(info.st_mode);
    close(original);
    if (!valid) return NO;
    char *temporary = strdup([[container stringByAppendingPathComponent:@".rv-karing-XXXXXX"] fileSystemRepresentation]);
    int fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return NO; }
    valid = fchmod(fd, info.st_mode & 0777) == 0;
    struct stat current;
    if (valid && fstat(fd, &current) == 0 && (current.st_uid != info.st_uid || current.st_gid != info.st_gid))
        valid = fchown(fd, info.st_uid, info.st_gid) == 0;
    NSUInteger offset = 0;
    while (valid && offset < data.length) {
        ssize_t count = write(fd, (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { valid = NO; break; }
        offset += (NSUInteger)count;
    }
    if (valid) valid = fsync(fd) == 0;
    if (close(fd) != 0) valid = NO;
    if (valid) valid = rename(temporary, path.fileSystemRepresentation) == 0;
    if (!valid) unlink(temporary);
    free(temporary);
    return valid;
}

static void ReplaceSelectedRoutes(id object, NSString *old, NSString *selected) {
    if ([object isKindOfClass:NSMutableDictionary.class]) {
        if ([object[@"outbound"] isEqual:old]) object[@"outbound"] = selected;
        // Logical rules contain nested rules; opaque future fields stay opaque.
        if ([object[@"rules"] isKindOfClass:NSArray.class]) ReplaceSelectedRoutes(object[@"rules"], old, selected);
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) ReplaceSelectedRoutes(value, old, selected);
    }
}

NSDictionary *TVKaringSelectionDocuments(NSDictionary *documents, NSDictionary *selection) {
    NSDictionary *(^reject)(NSString *) = ^NSDictionary *(NSString *error) { return @{@"error":error, @"outcome":@"not_sent"}; };
    if (![selection isKindOfClass:NSDictionary.class]) return reject(@"invalid_selection");
    for (NSString *key in selection) if (![@[@"exit_tag",@"relay_tag",@"upstream_group"] containsObject:key]) return reject(@"invalid_selection");
    NSString *exit = selection[@"exit_tag"], *relay = selection[@"relay_tag"], *group = selection[@"upstream_group"];
    if ((id)relay == NSNull.null) relay = nil;
    if ((id)group == NSNull.null) group = nil;
    if (![exit isKindOfClass:NSString.class] || !exit.length ||
        (relay && (![relay isKindOfClass:NSString.class] || !relay.length || [relay isEqual:exit])) ||
        (group && (![group isKindOfClass:NSString.class] || !group.length)) || ((relay != nil) != (group != nil))) return reject(@"invalid_selection");
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:documents options:0 error:nil];
    NSMutableDictionary *result = encoded ? [NSJSONSerialization JSONObjectWithData:encoded options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *core=result[@"service_core.json"], *settings=result[@"karing_setting.json"], *use=result[@"karing_subscribe_use.json"];
    NSArray *items=result[@"karing_subscribe.json"][@"items"], *outbounds=core[@"outbounds"];
    if (![core isKindOfClass:NSMutableDictionary.class] || ![settings isKindOfClass:NSMutableDictionary.class] ||
        ![use isKindOfClass:NSMutableDictionary.class] || ![items isKindOfClass:NSArray.class] || ![outbounds isKindOfClass:NSArray.class]) return reject(@"selection_documents_invalid");
    NSMutableSet *tags=[NSMutableSet set]; BOOL relayMember=NO;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) return reject(@"selection_documents_invalid");
        if ([item[@"enable"] isEqual:@NO]) continue;
        if (![item[@"servers"] isKindOfClass:NSArray.class]) return reject(@"selection_documents_invalid");
        for (NSDictionary *server in item[@"servers"]) {
            if (![server isKindOfClass:NSDictionary.class]) return reject(@"selection_documents_invalid");
            NSString *tag=server[@"tag"];
            if (![tag isKindOfClass:NSString.class] || !tag.length || [tags containsObject:tag]) return reject(@"ambiguous_profile_node");
            [tags addObject:tag];
            if ([item[@"groupid"] isEqual:group] && [tag isEqual:relay]) relayMember=YES;
        }
    }
    if (![tags containsObject:exit] || (relay && !relayMember)) return reject(@"selection_node_unavailable");
    NSMutableDictionary *exitOutbound=nil, *relayOutbound=nil;
    NSMutableSet *seen=[NSMutableSet set];
    NSArray *oldChain=settings[@"chain_proxy"];
    if (![oldChain isKindOfClass:NSArray.class]) return reject(@"chain_configuration_unsupported");
    for (NSMutableDictionary *outbound in outbounds) {
        if (![outbound isKindOfClass:NSMutableDictionary.class]) return reject(@"selection_documents_invalid");
        NSString *tag=outbound[@"tag"];
        if (![tag isKindOfClass:NSString.class] || [seen containsObject:tag]) return reject(@"ambiguous_core_node");
        [seen addObject:tag];
        if (![tags containsObject:tag]) continue;
        id detour=outbound[@"detour"];
        if (detour && ![oldChain containsObject:detour]) return reject(@"custom_node_detour_unsupported");
        [outbound removeObjectForKey:@"detour"];
        if ([tag isEqual:exit]) exitOutbound=outbound;
        if ([tag isEqual:relay]) relayOutbound=outbound;
    }
    if (!exitOutbound || (relay && !relayOutbound)) return reject(@"selection_core_node_unavailable");
    NSMutableDictionary *route=core[@"route"];
    NSString *old=route[@"final"];
    if (![route isKindOfClass:NSMutableDictionary.class] || ![old isKindOfClass:NSString.class] ||
        ![tags containsObject:old] || ![use[@"select_default"] isEqual:old]) return reject(@"selection_route_unsupported");
    ReplaceSelectedRoutes(route[@"rules"], old, exit);
    route[@"final"]=exit;
    id dns=core[@"dns"];
    if ([dns isKindOfClass:NSDictionary.class] && [dns[@"servers"] isKindOfClass:NSArray.class])
        for (NSMutableDictionary *server in dns[@"servers"]) if ([server isKindOfClass:NSMutableDictionary.class] && [server[@"detour"] isEqual:old]) server[@"detour"]=exit;
    if (relay) exitOutbound[@"detour"]=relay;
    settings[@"chain_proxy"]=relay?@[relay]:@[];
    settings[@"front"]=@YES;
    use[@"select_default"]=exit;
    return @{@"data":result};
}
