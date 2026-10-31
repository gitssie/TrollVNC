#import "../include/TVAppStateServices.h"
#import "TVASErrors.h"
NSError *TVASMakeError(NSString *code,NSString *message) {
    return [NSError errorWithDomain:@"TVAppStateServices" code:1 userInfo:@{@"errorCode":code,NSLocalizedDescriptionKey:message}];
}
NSDictionary *TVASErrorRecord(NSError *error) {
    error=error?:TVASMakeError(@"operation_failed",@"The operation returned no result.");
    NSString *code=[error.userInfo[@"errorCode"]isKindOfClass:NSString.class]?error.userInfo[@"errorCode"]:@"operation_failed";
    if(!code.length)code=@"operation_failed";
    NSString *message=error.localizedDescription.length?error.localizedDescription:@"The operation failed.";
    NSMutableDictionary *value=[@{@"error_code":code,@"domain":error.domain,@"code":@(error.code),@"message":[message substringToIndex:MIN(message.length,2048)],@"outcome_unknown":@([error.userInfo[@"outcomeUnknown"]boolValue]),@"state_may_be_partial":@([error.userInfo[@"stateMayBePartial"]boolValue]),@"archive_may_be_partial":@([error.userInfo[@"archiveMayBePartial"]boolValue])}mutableCopy];
    for(NSString *key in @[@"sourceDomain",@"sourceCode",@"posixCode"]) {
        id item=error.userInfo[key];
        if(([key isEqual:@"sourceDomain"] && [item isKindOfClass:NSString.class]) || (![key isEqual:@"sourceDomain"] && [item isKindOfClass:NSNumber.class]))value[@{@"sourceDomain":@"source_domain",@"sourceCode":@"source_code",@"posixCode":@"posix_code"}[key]]=item;
    }
    NSString *backup=error.userInfo[@"backupIDFV"];
    if([backup isKindOfClass:NSString.class] && [[NSUUID alloc]initWithUUIDString:backup])value[@"backup_id"]=[@"snapshot:"stringByAppendingString:[[NSUUID alloc]initWithUUIDString:backup].UUIDString];
    if([error.userInfo[@"step"]isKindOfClass:NSString.class])value[@"step"]=error.userInfo[@"step"];
    return value;
}
NSDictionary *TVASHTTPError(NSError *error) {
    NSMutableDictionary *value=[TVASErrorRecord(error)mutableCopy];value[@"error"]=value[@"message"];return value;
}
NSInteger TVASErrorHTTPStatus(NSError *error) {
    NSDictionary *record=TVASErrorRecord(error);
    NSString *code=record[@"error_code"];
    if([record[@"outcome_unknown"]boolValue] || [code isEqual:@"outcome_unknown"])return 504;
    if([code isEqual:@"permission_denied"])return 403;
    if([code isEqual:@"snapshot_unavailable"])return 404;
    if([@[@"busy",@"restore_pending",@"pending_source",@"same_identity",@"active_environment",@"snapshot_changed",@"ownership_conflict",@"idfv_mismatch"]containsObject:code])return 409;
    if([@[@"shadow_unavailable",@"shadow_incompatible",@"service_stopping"]containsObject:code])return 503;
    if([code isEqual:@"invalid_request"])return 400;
    if([code isEqual:@"unsupported_operation"])return 400;
    if([code isEqual:@"invalid_archive"])return 422;
    return 500;
}

static NSDictionary *Bad(NSError **error) {
    if(error)*error=[NSError errorWithDomain:@"TVAppStateRequest" code:1 userInfo:@{@"errorCode":@"invalid_request",NSLocalizedDescriptionKey:@"Invalid AppState request parameters."}];return nil;
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
    NSDictionary *map=@{@"backup_and_reset":@"backupAndReset",@"claim":@"claim",@"release":@"release",@"ownership":@"ownership",@"list":@"catalog",@"backup":@"backup",@"restore":@"restore",@"verify":@"verify",@"describe":@"describe",@"profile":@"profile",@"sessionSupplement":@"sessionSupplement",@"save":@"save",@"createBaseline":@"baseline",@"switch":@"switch",@"edit":@"edit",@"delete":@"delete",@"launch":@"launch",@"stop":@"stop",@"status":@"status"};
    if([method isKindOfClass:NSString.class] && !map[method]){if(error)*error=TVASMakeError(@"unsupported_operation",@"Unsupported AppState operation.");return nil;}
    if(![method isKindOfClass:NSString.class] || !map[method] || ![params isKindOfClass:NSDictionary.class] || !TVASComponent(params[@"bundle_id"]))return Bad(error);
    NSMutableSet *allowed=[NSMutableSet setWithObject:@"bundle_id"];
    BOOL reference=[@[@"switch",@"edit",@"delete",@"restore",@"verify",@"profile",@"sessionSupplement",@"claim",@"release",@"ownership"] containsObject:method];
    if(reference)[allowed addObject:@"backup_id"];
    if([method isEqual:@"backup_and_reset"])[allowed addObject:@"idfv"];
    if([@[@"save",@"backup",@"switch",@"edit"] containsObject:method])[allowed addObjectsFromArray:@[@"display_name",@"note"]];
    if([method isEqual:@"switch"])[allowed addObject:@"discard_current"];
    if([method isEqual:@"restore"])[allowed addObject:@"save_current"];
    if([method isEqual:@"sessionSupplement"])[allowed addObjectsFromArray:@[@"idfv",@"access_token",@"refresh_token"]];
    if([@[@"edit",@"delete",@"verify"]containsObject:method])[allowed addObject:@"requester"];
    if(params[@"requester"] && ![@[@"phone",@"rv"]containsObject:params[@"requester"]])return Bad(error);
    for(id key in params)if(![allowed containsObject:key])return Bad(error);
    NSMutableDictionary *request=[@{@"operation":map[method]} mutableCopy];
    if(params[@"requester"])request[@"requester"]=params[@"requester"];
    if([method isEqual:@"backup_and_reset"]) {
        if(![params[@"idfv"]isKindOfClass:NSString.class])return Bad(error);
        NSUUID *idfv=[[NSUUID alloc]initWithUUIDString:params[@"idfv"]];if(!idfv)return Bad(error);
        request[@"idfv"]=idfv.UUIDString;
    }
    if(reference) {
        NSString *ref=Reference(params[@"backup_id"],params[@"bundle_id"]);
        if(!ref || ([@[@"edit",@"profile",@"sessionSupplement"] containsObject:method] && ![params[@"backup_id"] hasPrefix:@"snapshot:"]))return Bad(error);
        request[@"reference"]=ref;
    }
    if([@[@"restore",@"delete",@"verify",@"claim",@"release",@"ownership"]containsObject:method]) {
        NSString *backup=params[@"backup_id"];
        if(![backup hasPrefix:@"snapshot:"] || ![[NSUUID alloc]initWithUUIDString:[backup substringFromIndex:9]])return Bad(error);
    }
    if([method isEqual:@"restore"]) {
        id save=params[@"save_current"]?:@YES;
        if(![save isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)save)!=CFBooleanGetTypeID())return Bad(error);
        request[@"saveCurrent"]=save;
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
