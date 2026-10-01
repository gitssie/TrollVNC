// GPL-2.0-only.
#import "TVNCSettingsModel.h"
#import "TVNCServiceStatus.h"
#import <netdb.h>

NSNotificationName const TVNCSettingsDidChangeNotification = @"com.82flex.trollvnc.settings-edited";
NSString *TVNCUIString(NSBundle *bundle, NSString *key) {
    NSString *text = NSLocalizedStringFromTableInBundle(key, @"Localizable", bundle, nil);
    return [text isEqualToString:key] ? NSLocalizedStringFromTableInBundle(key, @"Root", bundle, nil) : text;
}
NSDictionary *TVNCSettingsCatalog(NSBundle *bundle) {
    return [NSDictionary dictionaryWithContentsOfFile:[bundle pathForResource:@"SettingsCatalog" ofType:@"plist"]] ?: @{};
}
id TVNCSettingValue(NSUserDefaults *preferences, NSDictionary *row) {
    return [preferences objectForKey:row[@"key"]] ?: row[@"default"] ?: @"";
}
NSString *TVNCSettingDisplay(NSUserDefaults *preferences, NSDictionary *row, NSBundle *bundle) {
    id value = TVNCSettingValue(preferences, row);
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"secret"]) return [value description].length ? @"••••••••" : TVNCUIString(bundle, @"Not set");
    NSArray *choices = row[@"choiceValues"];
    if (choices) {
        NSUInteger index = [choices indexOfObject:value];
        return index < [row[@"choiceTitles"] count] ? TVNCUIString(bundle, row[@"choiceTitles"][index]) : [value description];
    }
    if (row[@"format"]) return [NSString stringWithFormat:TVNCUIString(bundle, row[@"format"]), [value doubleValue]];
    NSString *text = [value description];
    if (!text.length) {
        NSString *key = row[@"key"];
        if ([key isEqualToString:@"BindHost"]) return TVNCUIString(bundle, @"All interfaces");
        if ([key isEqualToString:@"HttpDir"]) return TVNCUIString(bundle, @"Built-in assets");
        return TVNCUIString(bundle, @"Not set");
    }
    return text;
}
static BOOL TVNCSettingError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TVNCSettings" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
BOOL TVNCWriteSetting(NSUserDefaults *preferences, NSDictionary *row, id value, NSError **error) {
    NSString *key = row[@"key"], *kind = row[@"kind"];
    if (!key.length) return TVNCSettingError(error, @"Invalid setting");
    if ([kind isEqualToString:@"port"]) {
        int port = TVNCParseServicePort(value, [key isEqualToString:@"HttpPort"]);
        int vnc = [key isEqualToString:@"Port"] ? port : TVNCParseServicePort([preferences objectForKey:@"Port"] ?: @5901, NO);
        int zx = [key isEqualToString:@"ZXTouchPort"] ? port : TVNCParseServicePort([preferences objectForKey:@"ZXTouchPort"] ?: @6000, NO);
        int http = [key isEqualToString:@"HttpPort"] ? port : TVNCParseServicePort([preferences objectForKey:@"HttpPort"] ?: @0, YES);
        if (!TVNCServicePortsValid(vnc, zx, http)) return TVNCSettingError(error, @"Ports must be distinct and within 1024–65535. HTTP may be 0. Ports 46751 and 46752 are reserved.");
        value = @(port);
    } else if ([kind isEqualToString:@"number"] || [kind isEqualToString:@"slider"]) {
        double number = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[value description]];
        if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number) ||
            (row[@"min"] && number < [row[@"min"] doubleValue]) ||
            (row[@"max"] && number > [row[@"max"] doubleValue]) ||
            ([row[@"integer"] boolValue] && floor(number) != number))
            return TVNCSettingError(error, @"Enter a value within the displayed range.");
        if ([key isEqualToString:@"KeepAliveSec"] && number > 0 && number < 15)
            return TVNCSettingError(error, @"Keepalive must be 0 or 15–300 seconds.");
        value = @(number);
    } else if ([kind isEqualToString:@"choice"]) {
        if (![row[@"choiceValues"] containsObject:value]) return TVNCSettingError(error, @"Invalid selection");
    } else if ([kind isEqualToString:@"switch"]) {
        value = @([value boolValue]);
    } else {
        if (![value isKindOfClass:NSString.class]) return TVNCSettingError(error, @"Invalid text");
        if (![kind isEqualToString:@"secret"]) value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([key isEqualToString:@"BindHost"] && [value length]) {
            struct addrinfo hints = {0}, *result = NULL;
            hints.ai_flags = AI_NUMERICHOST; hints.ai_socktype = SOCK_STREAM;
            int status = getaddrinfo([value UTF8String], NULL, &hints, &result);
            if (result) freeaddrinfo(result);
            if (status != 0) return TVNCSettingError(error, @"Bind address must be a valid IPv4/IPv6 literal, or empty to listen on all interfaces.");
            if ([preferences dictionaryForKey:@"WireGuardConfig"] && !TVNCSharedBindAllowsWireGuard(value))
                return TVNCSettingError(error, @"Clear the shared listen address to use both Wi-Fi and WireGuard.");
        }
        if ([@[@"HttpDir", @"SslCertFile", @"SslKeyFile"] containsObject:key] && [value length] && ![value hasPrefix:@"/"])
            return TVNCSettingError(error, @"Enter an absolute file path, or leave empty for the default.");
    }
    id previous = [preferences objectForKey:key];
    [preferences setObject:value forKey:key];
    if (![preferences synchronize]) {
        if (previous) [preferences setObject:previous forKey:key]; else [preferences removeObjectForKey:key];
        return TVNCSettingError(error, @"Could not save this setting.");
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:TVNCSettingsDidChangeNotification object:nil];
    return YES;
}
