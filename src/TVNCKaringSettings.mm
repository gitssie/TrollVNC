#import "TVNCHTTPServer.h"
NSDictionary *TVNCKaringDeviceSettings(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *overridePath = @"/var/mobile/Library/ZXTouch/config/tweak/karing.plist";
    NSDictionary *override = [NSDictionary dictionaryWithContentsOfFile:overridePath];
    NSString *secret = [override[@"secret"] isKindOfClass:NSString.class] ? override[@"secret"] : nil;
    NSInteger port = 3057;
    NSMutableArray<NSString *> *containers = [NSMutableArray array];
    NSURL *group = [files containerURLForSecurityApplicationGroupIdentifier:@"group.com.nebula.karing"];
    if (group) [containers addObject:group.path];
    // The daemon lacks App Group entitlement. Identify only Karing's container.
    NSArray *roots = @[@"/var/mobile/Containers/Shared/AppGroup"];
    for (NSString *root in roots) {
        for (NSString *name in [files contentsOfDirectoryAtPath:root error:nil]) {
            NSString *path = [root stringByAppendingPathComponent:name];
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([metadata[@"MCMMetadataIdentifier"] isEqual:@"group.com.nebula.karing"]) [containers addObject:path];
        }
    }
    for (NSString *path in containers) {
        NSData *coreData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"service_core.json"]];
        id core = coreData ? [NSJSONSerialization JSONObjectWithData:coreData options:0 error:nil] : nil;
        id experimental = [core isKindOfClass:NSDictionary.class] ? core[@"experimental"] : nil;
        id api = [experimental isKindOfClass:NSDictionary.class] ? experimental[@"clash_api"] : nil;
        if (![api isKindOfClass:NSDictionary.class]) continue;
        if (!secret && [api[@"secret"] isKindOfClass:NSString.class]) secret = api[@"secret"];
        NSString *controller = [api[@"external_controller"] isKindOfClass:NSString.class] ? api[@"external_controller"] : nil;
        NSURLComponents *address = controller ? [NSURLComponents componentsWithString:[@"http://" stringByAppendingString:controller]] : nil;
        if (address.port.integerValue > 0 && address.port.integerValue <= 65535) port = address.port.integerValue;
        break;
    }
    return @{@"address": [NSString stringWithFormat:@"127.0.0.1:%ld", (long)port], @"secret": secret ?: @""};
}
