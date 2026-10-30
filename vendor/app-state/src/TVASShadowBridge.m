#import "TVASShadowBridge.h"
#import "TVASRuntime.h"
#import "SHDWAppStateClient.h"
NSDictionary *TVASInvokeShadow(NSString *action,NSString *bundle,NSDictionary *request,NSError **error) {
    return TVASInvokeShadowWithProgress(action,bundle,request,nil,error);
}
NSDictionary *TVASInvokeShadowWithProgress(NSString *action,NSString *bundle,NSDictionary *request,void (^progress)(NSDictionary *),NSError **error) {
    NSString *path=TVASRuntimePaths()[@"shadow_helper"];
    if(!path.length){if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:1 userInfo:@{@"errorCode":@"shadow_unavailable",NSLocalizedDescriptionKey:@"Shadow helper is unavailable"}];return nil;}
    SHDWAppStateClient *client=[[SHDWAppStateClient alloc]initWithHelperPath:path];
    NSDictionary *capabilities=[client invokeAction:@"capabilities" bundleIdentifier:bundle request:@{} progress:nil error:error];
    if(!capabilities)return nil;
    if(![capabilities isKindOfClass:NSDictionary.class] || ![capabilities[@"apiVersion"]isKindOfClass:NSNumber.class] || [capabilities[@"apiVersion"]integerValue]!=1 || ![capabilities[@"format"]isEqual:@"ShadowAppState2"] || ![capabilities[@"operations"]isKindOfClass:NSArray.class] || ![capabilities[@"operations"]containsObject:action]) {
        if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:2 userInfo:@{@"errorCode":@"shadow_incompatible",NSLocalizedDescriptionKey:@"Update Shadow: incompatible AppState helper"}];return nil;
    }
    id result=[client invokeAction:action bundleIdentifier:bundle request:request progress:progress error:error];
    if(!result)return nil;
    if(![result isKindOfClass:NSDictionary.class]){if(error)*error=[NSError errorWithDomain:@"TVASShadow" code:3 userInfo:@{@"errorCode":@"invalid_response",NSLocalizedDescriptionKey:@"Invalid Shadow helper result"}];return nil;}
    return result;
}
