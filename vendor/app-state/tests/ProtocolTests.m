#import "../include/TVAppStateServices.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d\n",__LINE__);exit(1);}}while(0)
int main(){@autoreleasepool{
    NSError *e=nil;
    CHECK(TVASRequest(@"profile",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01"},&e));
    CHECK(!TVASRequest(@"profile",@{@"bundle_id":@"test.app",@"backup_id":@"baseline:1"},&e));
    for(NSString *method in @[@"launch",@"stop",@"status"]) {
        CHECK(TVASRequest(method,@{@"bundle_id":@"test.app"},&e));
        CHECK(!TVASRequest(method,@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01"},&e));
    }
    CHECK(!TVASRequest(@"switch",@{@"bundle_id":@"test.app"},&e));
    CHECK(!TVASRequest(@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"../secret"},&e));
    CHECK(!TVASRequest(@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01",@"discard_current":@1},&e));
    CHECK(!TVASRequest(@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01",@"discard_current":@YES,@"display_name":@"Lost"},&e));
    CHECK(!TVASRequest(@"delete",@{@"bundle_id":@"test.app",@"backup_id":@"baseline:1.0"},&e));
    CHECK(!TVASRequest(@"edit",@{@"bundle_id":@"test.app",@"backup_id":@"baseline:1.0",@"display_name":@"No",@"note":@""},&e));
    CHECK(!TVASRequest(@"save",@{@"bundle_id":@"test.app",@"root":@"/tmp"},&e));
    NSDictionary *r=TVASRequest(@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01",@"discard_current":@NO},&e);
    CHECK([r[@"reference"]isEqual:@"test.app/snapshots/20261006-01"] && ![r[@"discardCurrent"]boolValue]);
    r=TVASRequest(@"save",@{@"bundle_id":@"test.app",@"note":@"note only"},&e);CHECK([r[@"accountPatch"][@"note"]isEqual:@"note only"]);
    CHECK(!TVASRequest(@"edit",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01",@"note":@""},&e));
    r=TVASResult(@{@"entries":@[@{@"reference":@"test.app/snapshots/20261006-01",@"kind":@"snapshot",@"name":@"20261006-01",@"version":@"1",@"build":@"2",@"savedAt":[NSDate dateWithTimeIntervalSince1970:0],@"account":@{@"displayName":@"Name",@"note":@"Note"}}],@"currentReference":@"test.app/snapshots/20261006-01",@"restorePending":@NO},@"test.app",&e);
    CHECK([r[@"current_backup_id"]isEqual:@"snapshot:20261006-01"] && [r[@"backups"][0][@"build"]isEqual:@"2"] && [NSJSONSerialization isValidJSONObject:r]);
    CHECK(!TVASResult(@{@"entries":@[],@"currentReference":@"other.app/snapshots/20261006-01"},@"test.app",&e));
    NSDictionary *target=@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53"};
    CHECK([TVASRequest(@"restore",target,&e)[@"saveCurrent"]boolValue]);
    NSMutableDictionary *retry=[target mutableCopy];retry[@"save_current"]=@NO;CHECK(![TVASRequest(@"restore",retry,&e)[@"saveCurrent"]boolValue]);
    retry[@"save_current"]=@1;CHECK(!TVASRequest(@"restore",retry,&e));
    CHECK(TVASRequest(@"delete",target,&e) && TVASRequest(@"verify",target,&e));
    CHECK(TVASRequest(@"backup",@{@"bundle_id":@"test.app"},&e)[@"accountPatch"]==nil);
    CHECK([TVASRequest(@"backup",@{@"bundle_id":@"test.app",@"note":@"note"},&e)[@"accountPatch"][@"note"]isEqual:@"note"]);
    puts("App-state command/backup-ID/JSON tests PASS");
}return 0;}
