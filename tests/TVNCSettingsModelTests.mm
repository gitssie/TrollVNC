// GPL-2.0-only.
#import "TVNCSettingsModel.h"
#include <cassert>
int main(int argc, char **argv) {
    assert(argc == 2);
    @autoreleasepool {
        NSDictionary *catalog = [NSDictionary dictionaryWithContentsOfFile:@(argv[1])];
        assert(catalog.count == 7);
        NSString *legacy = [@(argv[1]).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Root.plist"];
        NSArray *items = [NSDictionary dictionaryWithContentsOfFile:legacy][@"items"];
        NSMutableDictionary *original = [NSMutableDictionary dictionary], *rows = [NSMutableDictionary dictionary];
        for (NSDictionary *item in items) if (item[@"key"]) original[item[@"key"]] = item;
        for (NSDictionary *category in catalog.allValues)
            for (NSDictionary *group in category[@"groups"])
                for (NSDictionary *row in group[@"rows"]) if (row[@"key"]) {
                    assert(!rows[row[@"key"]]); rows[row[@"key"]] = row;
                    id expected = original[row[@"key"]][@"default"];
                    assert((!expected && !row[@"default"]) || [expected isEqual:row[@"default"]]);
                }
        assert(original.count == 37 && [[NSSet setWithArray:original.allKeys] isEqual:[NSSet setWithArray:rows.allKeys]]);
        NSString *dashboardPath = [@(argv[1]).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Dashboard.plist"];
        NSArray *dashboardItems = [NSDictionary dictionaryWithContentsOfFile:dashboardPath][@"items"];
        NSMutableArray *groupSizes = [NSMutableArray array];
        NSMutableSet *actions = [NSMutableSet set];
        NSInteger groupSize = -1;
        for (NSDictionary *item in dashboardItems) {
            if ([item[@"cell"] isEqualToString:@"PSGroupCell"]) {
                if (groupSize >= 0) [groupSizes addObject:@(groupSize)];
                groupSize = 0;
            } else {
                assert(groupSize >= 0 && [item[@"tvncDashboardRow"] boolValue]);
                assert([item[@"cellClass"] isEqualToString:@"TVNCDashboardCell"]);
                assert(!item[@"key"]); // navigation must never overwrite a preference
                if (item[@"action"]) {
                    assert(![actions containsObject:item[@"action"]]);
                    [actions addObject:item[@"action"]];
                }
                ++groupSize;
            }
        }
        [groupSizes addObject:@(groupSize)];
        assert(([groupSizes isEqual:@[@1, @7, @2]] && actions.count == 8));
        NSString *suite = [@"com.82flex.trollvnc.settings-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [preferences setObject:@"secret-value" forKey:@"FullPassword"];
        NSError *error = nil;
        assert(TVNCWriteSetting(preferences, rows[@"ClipboardEnabled"], @NO, &error));
        assert([[preferences stringForKey:@"FullPassword"] isEqualToString:@"secret-value"]);
        assert([TVNCSettingDisplay(preferences, rows[@"FullPassword"], NSBundle.mainBundle) isEqualToString:@"••••••••"]);
        assert(!TVNCWriteSetting(preferences, rows[@"ZXTouchPort"], @"5901", &error));
        assert(![preferences objectForKey:@"ZXTouchPort"]);
        assert(!TVNCWriteSetting(preferences, rows[@"Port"], @"6000abc", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"Port"], @"46752", &error));
        assert(TVNCWriteSetting(preferences, rows[@"Port"], @"5902", &error));
        assert(TVNCWriteSetting(preferences, rows[@"ZXTouchPort"], @"6002", &error));
        NSUserDefaults *reloaded = [[NSUserDefaults alloc] initWithSuiteName:suite];
        assert([reloaded integerForKey:@"ZXTouchPort"] == 6002);
        assert(!TVNCWriteSetting(preferences, rows[@"Scale"], @"1.5", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"MaxInflight"], @"2.5", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"TileSize"], @"NaN", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"KeepAliveSec"], @"10", &error));
        assert(TVNCWriteSetting(preferences, rows[@"KeepAliveSec"], @"15", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"ReverseMode"], @"invalid", &error));
        assert(TVNCWriteSetting(preferences, rows[@"ReverseMode"], @"viewer", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"SslCertFile"], @"relative.pem", &error));
        assert(TVNCWriteSetting(preferences, rows[@"SslCertFile"], @"/tmp/cert.pem", &error));
        assert(!TVNCWriteSetting(preferences, rows[@"BindHost"], @"hostname.invalid", &error));
        [preferences setObject:@{} forKey:@"WireGuardConfig"];
        assert(!TVNCWriteSetting(preferences, rows[@"BindHost"], @"192.168.1.2", &error));
        assert(TVNCWriteSetting(preferences, rows[@"BindHost"], @"::", &error));
        assert([[preferences stringForKey:@"BindHost"] isEqualToString:@"0.0.0.0"]);
        assert(!TVNCWriteSetting(preferences, rows[@"BindHost"], @"fe80::1", &error));
        assert(TVNCWriteSetting(preferences, rows[@"FullPassword"], @"", &error));
        assert([preferences stringForKey:@"FullPassword"].length == 0);
        [preferences removePersistentDomainForName:suite]; [preferences synchronize];
        NSLog(@"37 settings preserved; defaults, persistence, passwords and invalid-edit rollback verified");
    }
}
