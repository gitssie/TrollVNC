#import "TVAppProfile.h"
#include <sqlite3.h>
#include <sys/stat.h>

static NSDictionary *CachedHeaders(NSString *directory, NSDictionary *manifest) {
    NSString *relative=nil;
    for(NSDictionary *entry in manifest[@"containerInventories"][@"data"])
        if([entry[@"type"]isEqual:@"file"] && [entry[@"path"]hasSuffix:@"/Cache.db"] && entry[@"sha256"]){relative=entry[@"path"];break;}
    if(!relative)return @{};
    NSString *path=[[directory stringByAppendingPathComponent:@"containers/data"]stringByAppendingPathComponent:relative];
    struct stat st;if(lstat(path.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode))return @{};
    sqlite3 *db=NULL;sqlite3_stmt *statement=NULL;NSMutableDictionary *headers=[NSMutableDictionary new];
    if(sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL)==SQLITE_OK &&
        sqlite3_prepare_v2(db,"SELECT b.request_object FROM cfurl_cache_response r JOIN cfurl_cache_blob_data b ON b.entry_ID=r.entry_ID ORDER BY r.time_stamp DESC,r.entry_ID DESC LIMIT 256",-1,&statement,NULL)==SQLITE_OK) {
        while(sqlite3_step(statement)==SQLITE_ROW) {
            int size=sqlite3_column_bytes(statement,0);if(size<=0 || size>65536)continue;
            NSData *data=[NSData dataWithBytes:sqlite3_column_blob(statement,0) length:(NSUInteger)size];
            NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            NSArray *array=[plist isKindOfClass:NSDictionary.class]?plist[@"Array"]:nil;
            if(![array isKindOfClass:NSArray.class] || array.count<=19 || ![array[1]isKindOfClass:NSDictionary.class] || ![array[19]isKindOfClass:NSDictionary.class])continue;
            NSURL *url=[NSURL URLWithString:array[1][@"_CFURLString"]?:@""];
            if(![url.scheme isEqual:@"https"] || ![@[@"www.vinted.com",@"api.vinted.com"]containsObject:url.host] || !array[19][@"Authorization"])continue;
            for(NSString *key in @[@"X-Session-Id",@"Accept",@"Locale",@"Accept-Language",@"X-Anon-Id",@"X-V-Udt",@"X-Device-UUID",@"User-Agent",@"Short-Bundle-Version",@"X-ICloud-Identifier",@"X-Device-Model",@"X-App-Version"])
                if([array[19][key]isKindOfClass:NSString.class])headers[key]=array[19][key];
            break;
        }
    }
    if(statement)sqlite3_finalize(statement);if(db)sqlite3_close(db);return headers;
}
NSDictionary *TVReadAppProfile(NSString *directory,NSDictionary *manifest,NSArray *records,TVSessionSupplementStore *store,NSError **error) {
    NSString *bundle=manifest[@"bundleID"],*idfv=manifest[@"idfv"];
    if(![bundle isEqual:@"lt.manodrabuziai.fr"])return @{@"bundle_id":bundle,@"idfv":idfv?:@"",@"supported":@NO};
    NSUUID *identity=[[NSUUID alloc]initWithUUIDString:idfv];
    if(!identity){if(error)*error=[NSError errorWithDomain:@"TVAppProfile" code:1 userInfo:nil];return nil;}
    NSArray *merged=[store mergeRecords:records manifest:manifest error:error];if(!merged)return nil;
    NSMutableDictionary *credentials=[NSMutableDictionary new];
    for(NSString *account in @[@"token",@"refresh_token"]) {
        NSUInteger count=0;NSString *value=nil;
        for(NSDictionary *record in merged)if([record[@"svce"]isEqual:@"Vintedfr"] && [record[@"acct"]isEqual:account]){
            count++;NSData *data=record[@"v_Data"];if([data isKindOfClass:NSData.class] && data.length<=65536)value=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
        }
        if(count==1 && value.length)credentials[[account isEqual:@"token"]?@"access_token":@"refresh_token"]=value;
    }
    credentials[@"headers"]=CachedHeaders(directory,manifest);
    return @{@"bundle_id":bundle,@"idfv":identity.UUIDString,@"supported":@YES,
        @"metadata":[[TVVintedProfileReader new]inspectRecords:merged],@"credentials":credentials};
}
