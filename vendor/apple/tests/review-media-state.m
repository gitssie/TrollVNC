#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
@interface NSObject (MediaState)
+ (id)defaultStore;
- (id)activeAccount;
- (NSString *)accountName;
@end
int main(void) {@autoreleasepool {
 dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices",RTLD_NOW);
 Class c=NSClassFromString(@"SSAccountStore");
 if(![c respondsToSelector:@selector(defaultStore)]) return 2;
 id store=[c defaultStore];if(![store respondsToSelector:@selector(activeAccount)]) return 2;
 id account=[store activeAccount];NSString *name=[account respondsToSelector:@selector(accountName)] ? [account accountName] : nil;
 NSString *fingerprint=@"none";
 if(name.length){NSData *data=[name dataUsingEncoding:NSUTF8StringEncoding];unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);NSMutableString *s=[NSMutableString new];for(unsigned int i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];fingerprint=s;}
 NSData *out=[NSJSONSerialization dataWithJSONObject:@{@"active_account_present":@(account!=nil),@"active_account_fingerprint":fingerprint} options:0 error:nil];fwrite(out.bytes,1,out.length,stdout);puts("");return 0;
}}
