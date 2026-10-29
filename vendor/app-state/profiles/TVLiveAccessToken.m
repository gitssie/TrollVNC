#import "TVLiveAccessToken.h"
#import "../adapters/PXASNative.h"
#include <sqlite3.h>

static NSString *CurrentIDFV(NSString *bundle) {
    NSUserDefaults *defaults=[[NSUserDefaults alloc]initWithSuiteName:@"/var/mobile/Library/Preferences/me.jjolano.shadow.plist"];
    [defaults synchronize];
    id value=[defaults dictionaryForKey:bundle][@"Fingerprint_Data"][@"VendorIdentifier"];
    return [value isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:value].UUIDString:nil;
}
static NSDictionary *Headers(NSString *root, NSString *token) {
    if(!root.length)return @{};
    NSString *path=[root stringByAppendingPathComponent:@"Library/Caches/lt.manodrabuziai.fr/Cache.db"];
    sqlite3 *db=NULL;sqlite3_stmt *query=NULL;NSMutableDictionary *headers=[NSMutableDictionary new];
    if(sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL)==SQLITE_OK &&
       sqlite3_prepare_v2(db,"SELECT request_object FROM cfurl_cache_blob_data ORDER BY entry_ID DESC LIMIT 256",-1,&query,NULL)==SQLITE_OK) {
        while(sqlite3_step(query)==SQLITE_ROW) {
            int n=sqlite3_column_bytes(query,0);if(n<=0||n>65536)continue;
            NSData *bytes=[NSData dataWithBytes:sqlite3_column_blob(query,0) length:n];
            id plist=[NSPropertyListSerialization propertyListWithData:bytes options:0 format:NULL error:NULL];
            NSArray *array=[plist isKindOfClass:NSDictionary.class]?plist[@"Array"]:nil;
            if(![array isKindOfClass:NSArray.class]||array.count<=19||![array[19]isKindOfClass:NSDictionary.class])continue;
            NSDictionary *values=array[19];
            if(![values[@"Authorization"]isEqual:[@"Bearer " stringByAppendingString:token]])continue;
            for(NSString *key in @[@"X-Session-Id",@"Locale",@"Accept-Language",@"X-Anon-Id",@"X-V-Udt",@"X-Device-UUID",@"User-Agent",@"Short-Bundle-Version",@"X-ICloud-Identifier",@"X-Device-Model",@"X-App-Version"])
                if([values[key]isKindOfClass:NSString.class]&&[values[key]length]<=4096)headers[key]=values[key];
            break;
        }
    }
    if(query)sqlite3_finalize(query);if(db)sqlite3_close(db);return headers;
}
NSDictionary *TVReadLiveAccessToken(NSDictionary *target, NSError **error) {
    NSString *bundle=target[@"bundleID"];
    NSString *idfv=CurrentIDFV(bundle);
    if(![bundle isEqual:@"lt.manodrabuziai.fr"]||!idfv.length) {
        if(error)*error=[NSError errorWithDomain:@"TVLiveAccessToken" code:1 userInfo:@{NSLocalizedDescriptionKey:@"当前 Shadow 环境 IDFV 不可用"}];return nil;
    }
    PXASSecurityKeychain *reader=[[PXASSecurityKeychain alloc]initWithApplicationIdentifier:target[@"applicationIdentifier"]];
    NSString *token=[reader vintedAccessTokenForGroups:target[@"keychainGroups"] error:error];
    if(!token)return nil;
    if(![idfv isEqual:CurrentIDFV(bundle)]) {
        if(error)*error=[NSError errorWithDomain:@"TVLiveAccessToken" code:2 userInfo:@{NSLocalizedDescriptionKey:@"手机环境已切换，请重新获取"}];return nil;
    }
    NSMutableDictionary *result=[@{@"bundle_id":bundle,@"idfv":idfv,@"access_token":token,
        @"headers":Headers(target[@"containers"][@"data"],token)} mutableCopy];
    // Expiry is display/prefetch metadata; only the business server judges validity.
    NSArray *parts=[token componentsSeparatedByString:@"."];
    if(parts.count==3) {
        NSMutableString *payload=[[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
        [payload replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0,payload.length)];
        while(payload.length%4)[payload appendString:@"="];
        NSData *data=[[NSData alloc]initWithBase64EncodedString:payload options:0];
        id claims=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if([claims isKindOfClass:NSDictionary.class]&&[claims[@"exp"]isKindOfClass:NSNumber.class])result[@"expires_at"]=claims[@"exp"];
    }
    return result;
}
