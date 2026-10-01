// Shared daemon/UI service snapshot. GPL-2.0-only.
#pragma once
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

static NSString *const TVNCServiceRuntimeDomain = @"com.82flex.trollvnc.runtime";
static NSString *const TVNCServiceSnapshotKey = @"ServiceSnapshot";

NS_INLINE NSArray<NSString *> *TVNCWiFiAddresses(NSString *bindHost, BOOL ipv4, BOOL ipv6) {
    if (bindHost.length && ![@[@"0.0.0.0", @"::"] containsObject:bindHost])
        return ([bindHost containsString:@":"] ? ipv6 : ipv4) ? @[bindHost] : @[];
    NSMutableArray *addresses = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return addresses;
    for (struct ifaddrs *p = interfaces; p; p = p->ifa_next) {
        if (!p->ifa_addr || !(p->ifa_flags & IFF_UP) || strcmp(p->ifa_name, "en0")) continue;
        int family = p->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        if ((family == AF_INET && !ipv4) || (family == AF_INET6 && !ipv6)) continue;
        if ([bindHost isEqualToString:@"0.0.0.0"] && family != AF_INET) continue;
        char text[INET6_ADDRSTRLEN];
        const void *address = family == AF_INET ? (void *)&((struct sockaddr_in *)p->ifa_addr)->sin_addr : (void *)&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
        if (!inet_ntop(family, address, text, sizeof(text))) continue;
        NSString *ip = @(text);
        if (family == AF_INET6 && IN6_IS_ADDR_LINKLOCAL(&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr)) ip = [ip stringByAppendingString:@"%en0"];
        if (![addresses containsObject:ip]) [addresses addObject:ip];
    }
    freeifaddrs(interfaces); return addresses;
}

NS_INLINE BOOL TVNCServiceSnapshotValid(NSDictionary *status) {
    if (![status isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"VNCPort", @"ZXTouchPort", @"VNCRunning", @"ZXTouchRunning",
                            @"WireGuardConfigured", @"WireGuardStarted", @"VNCAcceptsIPv4", @"VNCAcceptsIPv6"])
        if (![status[key] isKindOfClass:NSNumber.class]) return NO;
    for (NSString *key in @[@"BindHost", @"WireGuardAddress", @"WireGuardError"])
        if (![status[key] isKindOfClass:NSString.class]) return NO;
    id addresses = status[@"LocalAddresses"];
    if (addresses && ![addresses isKindOfClass:NSArray.class]) return NO;
    for (id address in addresses) if (![address isKindOfClass:NSString.class]) return NO;
    return YES;
}

NS_INLINE NSDictionary *TVNCServiceSnapshotWithCurrentAddresses(NSDictionary *status) {
    if (!TVNCServiceSnapshotValid(status)) return nil;
    NSMutableDictionary *snapshot = [status mutableCopy];
    snapshot[@"LocalAddresses"] = TVNCWiFiAddresses(status[@"BindHost"], [status[@"VNCAcceptsIPv4"] boolValue], NO);
    return snapshot;
}

NS_INLINE BOOL TVNCWriteServiceSnapshot(NSUserDefaults *defaults, NSDictionary *status) {
    if (!TVNCServiceSnapshotValid(status) || ![status[@"ServerPID"] isKindOfClass:NSNumber.class]) return NO;
    [defaults setObject:status forKey:TVNCServiceSnapshotKey];
    return [defaults synchronize];
}

NS_INLINE BOOL TVNCServiceSnapshotProcessAlive(NSDictionary *status) {
    NSNumber *process = status[@"ServerPID"];
    if (![process isKindOfClass:NSNumber.class]) return NO;
    pid_t pid = (pid_t)process.intValue;
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

NS_INLINE NSDictionary *TVNCReadServiceSnapshot(NSUserDefaults *defaults) {
    [defaults synchronize];
    NSDictionary *status = [defaults dictionaryForKey:TVNCServiceSnapshotKey];
    if (!TVNCServiceSnapshotValid(status) || ![status[@"ServerPID"] isKindOfClass:NSNumber.class]) return nil;
    if (!TVNCServiceSnapshotProcessAlive(status)) return nil;
    return TVNCServiceSnapshotWithCurrentAddresses(status);
}
