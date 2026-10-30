#import "TVASShadowBridge.h"
#import "TVASRuntime.h"
#import "SHDWAppStateClient.h"
NSDictionary *TVASInvokeShadow(NSString *action,NSString *bundle,NSDictionary *request,NSError **error) {
    NSString *path=TVASRuntimePaths()[@"shadow_helper"];
    if(!path.length){if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Shadow helper is unavailable"}];return nil;}
    SHDWAppStateClient *client=[[SHDWAppStateClient alloc]initWithHelperPath:path];
    NSDictionary *capabilities=[client invokeAction:@"capabilities" bundleIdentifier:bundle request:@{} progress:nil error:error];
    if(!capabilities)return nil;
    if(![capabilities isKindOfClass:NSDictionary.class] || ![capabilities[@"apiVersion"]isKindOfClass:NSNumber.class] || [capabilities[@"apiVersion"]integerValue]!=1 || ![capabilities[@"format"]isEqual:@"ShadowAppState2"] || ![capabilities[@"operations"]isKindOfClass:NSArray.class] || ![capabilities[@"operations"]containsObject:action]) {
        if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Update Shadow: incompatible AppState helper"}];return nil;
    }
    id result=[client invokeAction:action bundleIdentifier:bundle request:request progress:nil error:error];
    if(!result)return nil;
    if(![result isKindOfClass:NSDictionary.class]){if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Invalid Shadow helper result"}];return nil;}
    return result;
}
