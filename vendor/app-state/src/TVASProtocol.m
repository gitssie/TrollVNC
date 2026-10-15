#import "../include/TVAppStateServices.h"
static NSDictionary *Bad(NSError **error) {
    if(error)*error=[NSError errorWithDomain:@"TVAppStateRequest" code:1 userInfo:nil];return nil;
}
static BOOL TVASComponent(id value) {
    if(![value isKindOfClass:NSString.class] || ![value length] || [value length]>200 || [value hasPrefix:@"."] || [value containsString:@".."])return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet]].location==NSNotFound;
}
static NSString *Reference(NSString *backup,NSString *bundle) {
    if(![backup isKindOfClass:NSString.class])return nil;
    NSArray *parts=[backup componentsSeparatedByString:@":"];
    if(parts.count!=2 || ![@[@"snapshot",@"baseline"] containsObject:parts[0]] || !TVASComponent(parts[1]))return nil;
    return [NSString stringWithFormat:@"%@/%@/%@",bundle,[parts[0] isEqual:@"snapshot"]?@"snapshots":@"baselines",parts[1]];
}
static NSString *BackupID(NSString *reference,NSString *bundle) {
    if(![reference isKindOfClass:NSString.class] || !reference.length)return @"";
    NSArray *parts=[reference componentsSeparatedByString:@"/"];
    if(parts.count!=3 || ![parts[0] isEqual:bundle] || ![@[@"snapshots",@"baselines"] containsObject:parts[1]] || !TVASComponent(parts[2]))return nil;
    return [NSString stringWithFormat:@"%@:%@",[parts[1] isEqual:@"snapshots"]?@"snapshot":@"baseline",parts[2]];
}
NSDictionary *TVASRequest(NSString *method,NSDictionary *params,NSError **error) {
    NSDictionary *map=@{@"list":@"catalog",@"describe":@"describe",@"profile":@"profile",@"sessionSupplement":@"sessionSupplement",@"save":@"save",@"createBaseline":@"baseline",@"switch":@"switch",@"edit":@"edit",@"delete":@"delete",@"launch":@"launch",@"stop":@"stop",@"status":@"status"};
    if(![method isKindOfClass:NSString.class] || !map[method] || ![params isKindOfClass:NSDictionary.class] || !TVASComponent(params[@"bundle_id"]))return Bad(error);
    NSMutableSet *allowed=[NSMutableSet setWithObject:@"bundle_id"];
    BOOL reference=[@[@"switch",@"edit",@"delete",@"profile",@"sessionSupplement"] containsObject:method];
    if(reference)[allowed addObject:@"backup_id"];
    if([@[@"save",@"switch",@"edit"] containsObject:method])[allowed addObjectsFromArray:@[@"display_name",@"note"]];
    if([method isEqual:@"switch"])[allowed addObject:@"discard_current"];
    if([method isEqual:@"sessionSupplement"])[allowed addObjectsFromArray:@[@"idfv",@"access_token",@"refresh_token"]];
    for(id key in params)if(![allowed containsObject:key])return Bad(error);
    NSMutableDictionary *request=[@{@"operation":map[method]} mutableCopy];
    if(reference) {
        NSString *ref=Reference(params[@"backup_id"],params[@"bundle_id"]);
        if(!ref || ([@[@"edit",@"profile",@"sessionSupplement"] containsObject:method] && ![params[@"backup_id"] hasPrefix:@"snapshot:"]))return Bad(error);
        request[@"reference"]=ref;
    }
    if([method isEqual:@"sessionSupplement"]) {
        if(![params[@"idfv"]isKindOfClass:NSString.class] || ![[NSUUID alloc]initWithUUIDString:params[@"idfv"]])return Bad(error);
        request[@"idfv"]=[[NSUUID alloc]initWithUUIDString:params[@"idfv"]].UUIDString;
        NSMutableDictionary *tokens=[NSMutableDictionary new];
        for(NSString *key in @[@"access_token",@"refresh_token"]) {
            NSString *value=params[key];if(![value isKindOfClass:NSString.class] || !value.length || value.length>65536)return Bad(error);
            tokens[[key isEqual:@"access_token"]?@"token":key]=[value dataUsingEncoding:NSUTF8StringEncoding];
        }
        request[@"tokens"]=tokens;
    }
    NSMutableDictionary *metadata=[NSMutableDictionary new];
    if(params[@"display_name"]) {
        id v=params[@"display_name"];
        if(![v isKindOfClass:NSString.class] || [v length]>100 || ![v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)return Bad(error);
        metadata[@"displayName"]=v;
    }
    if(params[@"note"]) {
        if(![params[@"note"] isKindOfClass:NSString.class] || [params[@"note"] length]>1000)return Bad(error);
        metadata[@"note"]=params[@"note"];
    }
    if([method isEqual:@"edit"]) {
        if(metadata.count!=2)return Bad(error);
        request[@"account"]=metadata;
    } else if(metadata.count)request[@"accountPatch"]=metadata;
    if(params[@"discard_current"]) {
        id value=params[@"discard_current"];
        if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID())return Bad(error);
        if([value boolValue] && metadata.count)return Bad(error);
        request[@"discardCurrent"]=value;
    }
    if(error)*error=nil;return request;
}
NSDictionary *TVASResult(NSDictionary *result,NSString *bundle,NSError **error) {
    if(![result isKindOfClass:NSDictionary.class])return Bad(error);
    if([result[@"bundle_id"] isEqual:bundle])return result; // sanitized describe
    if(![result[@"entries"] isKindOfClass:NSArray.class])return Bad(error);
    NSMutableArray *backups=[NSMutableArray new];
    NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];
    for(NSDictionary *entry in result[@"entries"]) {
        if(![entry isKindOfClass:NSDictionary.class] || ![@[@"snapshot",@"baseline"]containsObject:entry[@"kind"]] || ![entry[@"name"]isKindOfClass:NSString.class])return Bad(error);
        NSString *identifier=BackupID(entry[@"reference"],bundle);if(!identifier.length)return Bad(error);
        NSDictionary *account=entry[@"account"];
        if(account && (![account isKindOfClass:NSDictionary.class] || ![account[@"displayName"]isKindOfClass:NSString.class] || ![account[@"note"]isKindOfClass:NSString.class]))return Bad(error);
        NSMutableDictionary *item=[@{@"backup_id":identifier,@"kind":entry[@"kind"],@"display_name":account[@"displayName"]?:entry[@"name"],@"note":account[@"note"]?:@"",@"version":entry[@"version"]?:@"",@"build":entry[@"build"]?:@"",@"idfv":entry[@"IDFV"]?:NSNull.null,@"date":NSNull.null} mutableCopy];
        if([entry[@"savedAt"] isKindOfClass:NSDate.class])item[@"date"]=[formatter stringFromDate:entry[@"savedAt"]];
        [backups addObject:item];
    }
    NSString *current=BackupID(result[@"currentReference"],bundle);if(!current)return Bad(error);
    NSMutableDictionary *mapped=[@{@"bundle_id":bundle,@"backups":backups,@"current_backup_id":current.length?current:(id)NSNull.null,@"restore_pending":@([result[@"restorePending"] boolValue])} mutableCopy];
    if(result[@"pendingReference"]) {
        NSString *pending=BackupID(result[@"pendingReference"],bundle);if(!pending.length)return Bad(error);
        mapped[@"pending_backup_id"]=pending;
    }
    NSMutableArray *duplicates=[NSMutableArray new];
    for(NSString *ref in result[@"duplicateIdentityReferences"]) { NSString *identifier=BackupID(ref,bundle);if(!identifier.length)return Bad(error);[duplicates addObject:identifier]; }
    if(duplicates.count)mapped[@"duplicate_identity_backup_ids"]=duplicates;
    if(error)*error=nil;return mapped;
}
