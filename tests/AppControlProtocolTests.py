#!/usr/bin/env python3
"""Compile the real task-33 decoder on macOS and exercise protocol boundaries."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = r'''#import "AppControlProtocol.h"
#include <cassert>
static NSString *encode(NSDictionary *request) {
    return [[NSJSONSerialization dataWithJSONObject:request options:0 error:nil] base64EncodedStringWithOptions:0];
}
int main() { @autoreleasepool {
    NSMutableDictionary *r = [@{@"version":@1,@"op":@12,@"id":@1,@"token":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"payload":@{}} mutableCopy];
    assert(TVAppControlDecode(encode(r)));
    for (NSNumber *op in @[@7,@8,@9,@10,@11,@13,@14,@15,@17,@256]) { r[@"op"]=op; assert(!TVAppControlDecode(encode(r))); }
    r[@"op"]=@12;
    for (NSNumber *id in @[@0,@YES,@(-1),@1.5,@4294967296ULL]) { r[@"id"]=id; assert(!TVAppControlDecode(encode(r))); }
    r[@"id"]=@1;
    r[@"payload"]=@{@"text":[@"x" stringByPaddingToLength:4097 withString:@"x" startingAtIndex:0]};
    assert(!TVAppControlDecode(encode(r)));
    r[@"payload"]=@{}; r[@"op"]=@0; r[@"id"]=@0;
    assert(TVAppControlDecode(encode(r)));
    assert(!TVAppControlDecode(@"!invalid"));
    assert(TVAppControlMutation(12) && TVAppControlMutation(16) && !TVAppControlMutation(1));
    NSString *wire = [[NSString alloc] initWithData:TVAppControlEncode(r,nil,@"Expired") encoding:NSUTF8StringEncoding];
    assert([wire hasPrefix:@"0;;"] && [wire hasSuffix:@"\r\n"]);
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[wire substringWithRange:NSMakeRange(3,wire.length-5)] options:0];
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert([reply[@"status"] intValue]==1 && [reply[@"payload"][@"error"] isEqual:@"Expired"]);
} }
'''
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)
    (path / "test.mm").write_text(source)
    subprocess.run(["xcrun","clang++","-fobjc-arc","-std=c++17","-framework","Foundation","-I",str(root / "src"),str(path / "test.mm"),"-o",str(path / "test")],check=True)
    subprocess.run([str(path / "test")],check=True)
print("App control protocol boundaries passed")
