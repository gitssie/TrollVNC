#import "TVAppProfile.h"
static NSString *Token(NSArray *records,NSString *account) {
    NSString *result=nil;NSUInteger count=0;
    for(NSDictionary *record in records)if([record[@"svce"]isEqual:@"Vintedfr"] && [record[@"acct"]isEqual:account]) {
        count++;NSData *data=record[@"v_Data"];if([data isKindOfClass:NSData.class] && data.length<=65536)result=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    }
    return count==1 ? result : nil;
}
@implementation TVVintedProfileReader
- (NSDictionary *)inspectRecords:(NSArray *)records {
    NSString *token=Token(records,@"token");NSArray *parts=[token componentsSeparatedByString:@"."];
    NSMutableDictionary *metadata=[@{@"session":@"unknown",@"identity_source":@"cached_token_unverified",@"has_refresh_token":@(Token(records,@"refresh_token").length>0)}mutableCopy];
    if(parts.count==3) {
        NSString *part=[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];part=[part stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        while(part.length%4)part=[part stringByAppendingString:@"="];
        NSData *bytes=[[NSData alloc]initWithBase64EncodedString:part options:0];
        NSDictionary *claims=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
        if([claims isKindOfClass:NSDictionary.class]) {
            for(NSString *key in @[@"account_id",@"sub",@"cc",@"exp"])if([claims[key]isKindOfClass:NSString.class] || [claims[key]isKindOfClass:NSNumber.class])metadata[key]=claims[key];
            if([claims[@"exp"]isKindOfClass:NSNumber.class] && [claims[@"exp"]doubleValue]<=NSDate.date.timeIntervalSince1970)metadata[@"session"]=@"expired";
        }
    }
    if(metadata[@"account_id"])metadata[@"user_id"]=metadata[@"account_id"];
    if(metadata[@"cc"])metadata[@"market"]=metadata[@"cc"];
    return metadata;
}
@end
