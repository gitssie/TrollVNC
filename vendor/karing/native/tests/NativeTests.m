#import "TVKaringNative.h"
#import <NetworkExtension/NetworkExtension.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
static void Check(BOOL value, const char *label) {
    if (!value) { fprintf(stderr, "FAIL %s\n", label); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        Check([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil], "create fixture");
        @try {
            for (NSNumber *state in @[@(NEVPNStatusConnected),@(NEVPNStatusDisconnected),@(NEVPNStatusConnecting)]) {
                NSDictionary *value=TVKaringConnectionState(state.integerValue);
                NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
                Check(CFGetTypeID((__bridge CFTypeRef)decoded[@"vpn_connected"])==CFBooleanGetTypeID(),"VPN connected must serialize as JSON boolean");
                Check([decoded[@"vpn_connected"] boolValue]==(state.integerValue==NEVPNStatusConnected),"VPN connected value");
            }
            NSDictionary *source=@{
                @"karing_subscribe.json":@{@"items":@[
                    @{@"groupid":@"upstream",@"enable":@YES,@"servers":@[@{@"tag":@"one"},@{@"tag":@"two"}]},
                    @{@"groupid":@"exit-group",@"servers":@[@{@"tag":@"exit"}]}]},
                @"karing_setting.json":@{@"chain_proxy":@[@"one"],@"front":@YES,@"future":@42},
                @"karing_subscribe_use.json":@{@"select_default":@"two",@"fav":@[@"exit"]},
                @"service_core.json":@{
                    @"outbounds":@[@{@"tag":@"one",@"type":@"vless",@"secret":@"preserved"},@{@"tag":@"two",@"detour":@"one"},@{@"tag":@"exit",@"detour":@"one"},@{@"tag":@"direct_out",@"type":@"direct"}],
                    @"route":@{@"final":@"two",@"future":@{@"outbound":@"two"},@"rules":@[@{@"outbound":@"two"},@{@"outbound":@"direct_out"}]},
                    @"dns":@{@"servers":@[@{@"tag":@"proxy-dns",@"detour":@"two"},@{@"tag":@"local",@"detour":@"direct_out"}]}}};
            NSDictionary *chain=TVKaringSelectionDocuments(source,@{@"exit_tag":@"exit",@"upstream_group":@"upstream",@"relay_tag":@"two"})[@"data"];
            Check(chain != nil, "plan generic chain");
            Check([chain[@"service_core.json"][@"outbounds"][2][@"detour"] isEqual:@"two"] && !chain[@"service_core.json"][@"outbounds"][1][@"detour"], "exit through direct relay without cycle");
            Check([chain[@"service_core.json"][@"route"][@"final"] isEqual:@"exit"] && [chain[@"service_core.json"][@"route"][@"rules"][0][@"outbound"] isEqual:@"exit"], "update default and selected route rules");
            Check([chain[@"service_core.json"][@"dns"][@"servers"][0][@"detour"] isEqual:@"exit"] && [chain[@"service_core.json"][@"dns"][@"servers"][1][@"detour"] isEqual:@"direct_out"], "align selected DNS and preserve direct DNS");
            Check([chain[@"karing_setting.json"][@"future"] intValue]==42 && [chain[@"service_core.json"][@"outbounds"][0][@"secret"] isEqual:@"preserved"], "preserve unrelated configuration and node credentials");
            Check([source[@"service_core.json"][@"route"][@"final"] isEqual:@"two"], "planning does not mutate original");
            Check([chain[@"service_core.json"][@"route"][@"future"][@"outbound"] isEqual:@"two"],"preserve opaque route extensions");
            NSMutableDictionary *direct=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:source options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];
            direct[@"service_core.json"][@"route"][@"final"]=@"direct_out";
            Check(TVKaringSelectionDocuments(direct,@{@"exit_tag":@"exit"})[@"error"]!=nil,"reject rewriting built-in direct final and its rules");
            for (NSString *tag in @[@"one",@"two",@"exit"]) {
                NSDictionary *single=TVKaringSelectionDocuments(chain,@{@"exit_tag":tag,@"upstream_group":NSNull.null,@"relay_tag":NSNull.null})[@"data"];
                Check([single[@"karing_setting.json"][@"chain_proxy"] count]==0 && [single[@"karing_subscribe_use.json"][@"select_default"] isEqual:tag], "any node can be single exit");
                for (NSDictionary *outbound in single[@"service_core.json"][@"outbounds"]) Check(outbound[@"detour"]==nil,"single clears chain");
            }
            Check(TVKaringSelectionDocuments(source,@{@"exit_tag":@"exit",@"upstream_group":@"exit-group",@"relay_tag":@"two"})[@"error"]!=nil,"reject relay outside selected subscription");
            Check(TVKaringSelectionDocuments(source,@{@"exit_tag":@"exit",@"upstream_group":@"exit-group",@"relay_tag":@"exit"})[@"error"]!=nil,"reject self-chain");
            NSString *document = [root stringByAppendingPathComponent:@"service_core.json"];
            [@"{\"outbounds\":[{\"tag\":\"a\",\"future\":{\"unknown\":true}}],\"route\":{\"final\":\"a\"}}" writeToFile:document atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary *result = TVKaringReadDocument(root, @"service_core.json");
            Check([result[@"data"][@"outbounds"][0][@"future"][@"unknown"] boolValue], "preserve unknown fields");
            Check(TVKaringWriteDocument(root,@"service_core.json",chain[@"service_core.json"]),"atomic selection document write");
            Check([TVKaringReadDocument(root,@"service_core.json")[@"data"] isEqual:chain[@"service_core.json"]],"read back complete written configuration");
            Check(TVKaringReadDocument(root, @"../service_core.json")[@"error"] != nil, "reject filename traversal");
            Check(TVKaringReadDocument(root, @"karing_setting.json")[@"error"] != nil, "missing file");
            [@"broken" writeToFile:document atomically:YES encoding:NSUTF8StringEncoding error:nil];
            Check([TVKaringReadDocument(root, @"service_core.json")[@"error"] isEqual:@"invalid_document_json"], "malformed JSON");
            [files removeItemAtPath:document error:nil];
            [files createSymbolicLinkAtPath:document withDestinationPath:@"/etc/passwd" error:nil];
            Check(TVKaringReadDocument(root, @"service_core.json")[@"error"] != nil, "reject document symlink");
            Check(!TVKaringWriteDocument(root,@"service_core.json",@{}),"reject writing through document symlink");
            [files removeItemAtPath:document error:nil];
            [NSMutableData.data writeToFile:document atomically:YES];
            int fd = open(document.fileSystemRepresentation, O_WRONLY);
            Check(fd >= 0 && ftruncate(fd, 8 * 1024 * 1024 + 1) == 0, "large fixture"); close(fd);
            Check([TVKaringReadDocument(root, @"service_core.json")[@"error"] isEqual:@"document_unavailable"], "bound document size");
            NSString *helper = [root stringByAppendingPathComponent:@"helper"];
            [@"#!/bin/sh\nprintf '{\"data\":{\"future\":42},\"operation\":\"%s\"}\\n' \"$1\"\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(helper.fileSystemRepresentation, 0700);
            TVKaringHelperClient *client = [[TVKaringHelperClient alloc] initWithExecutable:helper];
            result = [client request:@"status"];
            Check([result[@"data"][@"future"] intValue] == 42 && [result[@"operation"] isEqual:@"status"], "argv / return passthrough");
            Check([[client request:@"status" parameters:@{@"unexpected":@YES}][@"outcome"] isEqual:@"not_sent"],"reject parameters on read operations");
            Check([[client request:@"status; touch /tmp/forbidden"][@"error"] isEqual:@"invalid_operation"], "reject arbitrary operations");
            [@"#!/bin/sh\ncat\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(helper.fileSystemRepresentation,0700);
            NSDictionary *parameters=@{@"exit_tag":@"arbitrary exit / 节点",@"relay_tag":NSNull.null,@"upstream_group":NSNull.null};
            Check([[client request:@"select" parameters:parameters] isEqual:parameters],"selection parameters pass privately through stdin");
            [@"#!/bin/sh\nprintf 'not-json'\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(helper.fileSystemRepresentation, 0700);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"unknown"], "malformed mutation response remains unknown");
            [@"#!/bin/sh\nexit 42\n" writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(helper.fileSystemRepresentation, 0700);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"unknown"], "failed helper cannot claim mutation failed safely");
            chmod(helper.fileSystemRepresentation, 0600);
            Check([[client request:@"reload"][@"outcome"] isEqual:@"not_sent"], "missing executable not sent");
            puts("PASS native document and helper transport regressions");
        } @finally { [files removeItemAtPath:root error:nil]; }
    }
    return 0;
}
