#import "../profiles/TVAppProfile.h"
#include <sys/stat.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Profile test failed at line %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    NSString *root=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    TVSessionSupplementStore *store=[[TVSessionSupplementStore alloc]initWithRoot:root];NSError *error=nil;
    NSString *bundle=@"lt.manodrabuziai.fr",*identity=@"C9EB7804-2062-4519-AC8D-6F68972574F3";
    NSDictionary *manifest=@{@"bundleID":bundle,@"idfv":identity};
    NSArray *records=@[@{@"svce":@"Vintedfr",@"acct":@"token",@"agrp":@"fixture.group",@"v_Data":[@"old-access"dataUsingEncoding:NSUTF8StringEncoding]},@{@"svce":@"Vintedfr",@"acct":@"refresh_token",@"agrp":@"fixture.group",@"v_Data":[@"old-refresh"dataUsingEncoding:NSUTF8StringEncoding]}];
    CHECK([[store mergeRecords:records manifest:manifest error:&error]isEqual:records]);
    NSDictionary *state=@{@"tokens":@{@"token":[@"new-access"dataUsingEncoding:NSUTF8StringEncoding],@"refresh_token":[@"new-refresh"dataUsingEncoding:NSUTF8StringEncoding]}};
    CHECK([store saveState:state bundle:bundle idfv:identity error:&error]);
    NSArray *merged=[store mergeRecords:records manifest:manifest error:&error];CHECK([merged[0][@"v_Data"]isEqual:state[@"tokens"][@"token"]]);CHECK([records[0][@"v_Data"]isEqual:[@"old-access"dataUsingEncoding:NSUTF8StringEncoding]]);CHECK([merged[0][@"agrp"]isEqual:records[0][@"agrp"]]);
    CHECK(([[store mergeRecords:records manifest:@{@"bundleID":bundle,@"idfv":@"7A70B21A-2F9D-4F66-81C4-6D21355758D7"} error:&error]isEqual:records]));
    NSDictionary *profile=TVReadAppProfile(root,manifest,records,store,&error);CHECK([profile[@"credentials"][@"access_token"]isEqual:@"new-access"]);CHECK([profile[@"metadata"][@"session"]isEqual:@"unknown"]);
    NSString *path=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.plist",bundle,identity]];
    NSMutableDictionary *envelope=[[NSDictionary dictionaryWithContentsOfFile:path]mutableCopy];envelope[@"sha256"]=@"invalid";[envelope writeToFile:path atomically:YES];chmod(path.fileSystemRepresentation,0600);
    CHECK(![store mergeRecords:records manifest:manifest error:&error]);
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];puts("Profile extraction, independent plist merge, IDFV isolation and checksum tests PASS");
}return 0;}
