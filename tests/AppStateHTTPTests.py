#!/usr/bin/env python3
'''Exercise the production AppState HTTP route bodies without UIKit/device access.'''
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#import <Foundation/Foundation.h>
#import "TVASErrors.h"
#import "TVNCHTTP.h"
#include <cstdlib>
#include <cstring>
static void Check(BOOL value,NSString *message){if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static TVNCHTTPResponse TVNCHTTPData(NSData *data,int status,const char *type){void *p=malloc(data.length);memcpy(p,data.bytes,data.length);return {(unsigned char *)p,data.length,(uint16_t)status,type,NULL};}
static TVNCHTTPResponse TVNCHTTPJSON(id value,int status){NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];Check(data!=nil,@"JSON serializable response");return TVNCHTTPData(data,status,"application/json");}
static NSDictionary *JSON(TVNCHTTPResponse response){id value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:response.data length:response.len] options:0 error:NULL];free(response.data);Check([value isKindOfClass:NSDictionary.class],@"JSON response object");return value;}
@interface FakeService:NSObject
@property(nonatomic,strong) NSError *failure;
@property(nonatomic,strong) NSDictionary *response;
@property(nonatomic,strong) NSDictionary *lastRequest;
@property(nonatomic) NSUInteger calls;
- (NSDictionary *)request:(NSDictionary *)request;
- (NSDictionary *)uploadStatePart:(NSDictionary *)params error:(NSError **)error;
- (NSData *)downloadStatePart:(NSDictionary *)params error:(NSError **)error;
@end
@implementation FakeService
- (NSDictionary *)request:(NSDictionary *)request{self.calls++;self.lastRequest=request;return self.response?:@{@"operation_id":@"op",@"status":@"running"};}
- (NSDictionary *)uploadStatePart:(NSDictionary *)params error:(NSError **)error{self.lastRequest=params;if(self.failure){*error=self.failure;return nil;}return @{@"ok":@YES,@"received":@17,@"complete":@YES};}
- (NSData *)downloadStatePart:(NSDictionary *)params error:(NSError **)error{self.lastRequest=params;if(self.failure){*error=self.failure;return nil;}return [NSData dataWithBytes:"\0\xff\1" length:3];}
@end
@interface Routes:NSObject { @public FakeService *_appStateService; FakeService *_appleService; }
- (TVNCHTTPResponse)route:(NSString *)path input:(NSDictionary *)input;
@end
@implementation Routes
- (instancetype)init{if((self=[super init])){_appStateService=[FakeService new];_appleService=[FakeService new];}return self;}
- (TVNCHTTPResponse)route:(NSString *)path input:(NSDictionary *)input{
__RAW_ROUTES__
__NATIVE_ROUTES__
return TVNCHTTPJSON(@{@"error":@"route_unavailable"},404);
}
@end
int main(){@autoreleasepool{
 Routes *routes=[Routes new];FakeService *service=routes->_appStateService;
 NSDictionary *params=@{@"bundle_id":@"local.fixture.app",@"backup_id":@"snapshot:11111111-1111-4111-8111-111111111111"};
 for(NSString *method in @[@"backup",@"restore",@"delete",@"verify"]){TVNCHTTPResponse response=[routes route:[@"/api/app-state/" stringByAppendingString:method] input:params];Check(response.status==200,@"accepted operation HTTP200");Check([JSON(response)[@"operation_id"]isEqual:@"op"],@"operation reference preserved");Check([service.lastRequest isEqual:@{@"action":@"invoke",@"method":method,@"params":params}],@"new operation dispatch preserves parameters");}
 JSON([routes route:@"/api/app-state/result" input:@{@"operation_id":@"existing"}]);Check([service.lastRequest isEqual:@{@"action":@"result",@"operation_id":@"existing"}],@"result query never invokes mutation");
 NSUInteger before=service.calls;TVNCHTTPResponse invalid=[routes route:@"/api/app-state/restore/extra" input:params];Check(invalid.status==404&&service.calls==before,@"nested route rejected before service");JSON(invalid);
 NSDictionary *statuses=@{@"busy":@409,@"active_environment":@409,@"restore_pending":@409,@"shadow_unavailable":@503,@"shadow_incompatible":@503,@"invalid_request":@400,@"permission_denied":@403,@"snapshot_unavailable":@404,@"invalid_archive":@422,@"operation_failed":@500,@"outcome_unknown":@504};
 for(NSString *code in statuses){service.failure=[NSError errorWithDomain:@"fixture.source" code:37 userInfo:@{@"errorCode":code,NSLocalizedDescriptionKey:@"中文错误说明",@"outcomeUnknown":@([code isEqual:@"outcome_unknown"]),@"stateMayBePartial":@YES,@"sourceDomain":@"native",@"sourceCode":@9,@"posixCode":@5,@"secret":@"must not escape"}];
  for(NSString *method in @[@"upload",@"download"]){TVNCHTTPResponse response=[routes route:[@"/api/app-state/" stringByAppendingString:method] input:params];Check(response.status==[statuses[code]intValue],[NSString stringWithFormat:@"HTTP status %@",code]);NSDictionary *error=JSON(response);Check([error[@"error_code"]isEqual:code]&&[error[@"error"]isEqual:@"中文错误说明"],@"stable code plus legacy string error");Check([error[@"code"]isEqual:@37]&&[error[@"source_code"]isEqual:@9]&&[error[@"posix_code"]isEqual:@5],@"numeric diagnostic compatibility");Check(error[@"secret"]==nil&&[error[@"state_may_be_partial"]boolValue]&&[error[@"outcome_unknown"]boolValue]==[code isEqual:@"outcome_unknown"],@"allowed fields and independent uncertainty");}
  service.response=@{@"error":TVASErrorRecord(service.failure)};TVNCHTTPResponse rejected=[routes route:@"/api/app-state/backup" input:params];Check(rejected.status==[statuses[code]intValue],@"synchronous operation rejection uses same status");JSON(rejected);
 }
 service.failure=nil;service.response=@{@"operation_id":@"op",@"status":@"completed",@"error":TVASErrorRecord(TVASMakeError(@"invalid_archive",@"校验失败"))};TVNCHTTPResponse completed=[routes route:@"/api/app-state/result" input:@{@"operation_id":@"op"}];Check(completed.status==200,@"completed operation outcome remains inside record");Check([JSON(completed)[@"error"][@"error_code"]isEqual:@"invalid_archive"],@"terminal stable error retained");
 TVNCHTTPResponse binary=[routes route:@"/api/app-state/download" input:params];Check(binary.status==200&&binary.len==3&&!strcmp(binary.content_type,"application/octet-stream")&&!memcmp(binary.data,"\0\xff\1",3),@"binary download unchanged");free(binary.data);
 Check([JSON([routes route:@"/api/app-state/upload" input:params])[@"ok"]boolValue],@"upload success unchanged");
 puts("AppState HTTP: production routes, four operations, polling, stable errors/statuses, legacy fields and binary responses passed");
}return 0;}
'''

def main():
    source = (ROOT / 'src/TVNCZXTouchService.mm').read_text()
    raw = source[source.index('    if ([path isEqual:@"/api/app-state/upload"])'):source.index('    if ([path isEqual:@"/api/app-state/stream"])')]
    native = source[source.index('    for (NSString *prefix in @[@"/api/apple/", @"/api/app-state/"])'):source.index('    if ([path isEqual:@"/api/device/info"])')]
    with tempfile.TemporaryDirectory(prefix='tvnc-app-state-http-') as directory:
        temp = Path(directory)
        harness = temp / 'main.mm'
        harness.write_text(HARNESS.replace('__RAW_ROUTES__', raw).replace('__NATIVE_ROUTES__', native))
        common = ['-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-g', '-O1', '-I'+str(ROOT/'vendor/app-state/src'), '-I'+str(ROOT/'control-http/include')]
        obj = temp/'protocol.o'
        subprocess.run(['xcrun','clang',*common,'-c',str(ROOT/'vendor/app-state/src/TVASProtocol.m'),'-o',str(obj)],check=True)
        binary = temp/'http-tests'
        subprocess.run(['xcrun','clang++','-std=c++20',*common,str(harness),str(obj),'-framework','Foundation','-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,env=dict(os.environ,ASAN_OPTIONS='detect_leaks=0:abort_on_error=1',UBSAN_OPTIONS='halt_on_error=1'))

if __name__ == '__main__':
    main()
