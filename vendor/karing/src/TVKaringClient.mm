// SPDX-License-Identifier: GPL-2.0-only
#import "TVKaringClient.h"
#import "KaringProtocol.hpp"
#include <mutex>

// Each request owns its delegate state; callbacks never retain stack references.
@interface TVKaringHTTPResponse : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) NSInteger status;
@property(nonatomic) BOOL done;
@property(nonatomic) BOOL streaming;
@property(nonatomic) NSUInteger wantedLines;
@end

@implementation TVKaringHTTPResponse
- (instancetype)init {
    if ((self = [super init])) {
        _condition = [NSCondition new];
        _data = [NSMutableData data];
    }
    return self;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    [self.condition lock];
    self.status = [(NSHTTPURLResponse *)response statusCode];
    [self.condition unlock];
    completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.condition lock];
    if (!self.done) {
        if (self.data.length + data.length > 4 * 1024 * 1024) {
            self.error = [NSError errorWithDomain:@"TVKaringHTTP" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Response exceeds 4 MiB"}];
            self.done = YES;
        } else {
            [self.data appendData:data];
            if (self.streaming && self.status == 200) {
                const unsigned char *bytes = (const unsigned char *)self.data.bytes;
                NSUInteger lines = 0;
                for (NSUInteger i = 0; i < self.data.length; ++i) {
                    if (bytes[i] == '\n' && ++lines >= self.wantedLines) {
                        [self.data setLength:i + 1];
                        self.done = YES;
                        break;
                    }
                }
            }
        }
        [self.condition signal];
    }
    [self.condition unlock];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.condition lock];
    if (!self.done) { self.error = error; self.done = YES; }
    [self.condition signal];
    [self.condition unlock];
}
@end

class FoundationHTTPClient final : public karing::IHTTPClient {
    karing::Config config_;
public:
    explicit FoundationHTTPClient(const karing::Config& config) : config_(config) {}
    karing::Error request(const std::string& method, const std::string& path, const std::string& body,
                         std::string& response, int& httpStatus) override {
        @autoreleasepool {
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:path.c_str()]];
            if (!url || !url.host) return {karing::ErrorCode::InvalidArgument, "Invalid URL"};
            BOOL traffic = [url.path isEqualToString:@"/traffic"];
            BOOL logs = [url.path isEqualToString:@"/logs"];
            NSTimeInterval timeout = config_.timeoutMs / 1000.0;
            if (logs) timeout = MIN(timeout, 2.0); // bounded live sample, not historical logs
            TVKaringHTTPResponse *state = [TVKaringHTTPResponse new];
            state.streaming = traffic || logs;
            state.wantedLines = 1;
            if (logs) {
                for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
                    if ([item.name isEqualToString:@"lines"]) state.wantedLines = MAX(1, MIN(1000, item.value.integerValue));
                }
            }
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.HTTPMethod = [NSString stringWithUTF8String:method.c_str()];
            [req setValue:[@"Bearer " stringByAppendingString:[NSString stringWithUTF8String:config_.secret.c_str()]] forHTTPHeaderField:@"Authorization"];
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            if (!body.empty()) {
                req.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            }
            NSURLSessionConfiguration *settings = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            settings.timeoutIntervalForRequest = timeout;
            settings.timeoutIntervalForResource = timeout;
            settings.connectionProxyDictionary = @{};
            NSOperationQueue *queue = [NSOperationQueue new];
            queue.maxConcurrentOperationCount = 1;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:settings delegate:state delegateQueue:queue];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
            [task resume];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
            [state.condition lock];
            while (!state.done && [state.condition waitUntilDate:deadline]) {}
            BOOL complete = state.done;
            NSError *error = state.error;
            httpStatus = (int)state.status;
            NSData *data = [state.data copy];
            state.done = YES;
            [state.condition unlock];
            [task cancel];
            [session invalidateAndCancel];
            if (error && error.code != NSURLErrorTimedOut) return {karing::ErrorCode::NetworkError, "HTTP transport failed"};
            // Return only complete newline-delimited records from a stream.
            if (state.streaming && httpStatus == 200) {
                const unsigned char *bytes = (const unsigned char *)data.bytes;
                NSUInteger length = 0;
                for (NSUInteger i = 0; i < data.length; ++i) if (bytes[i] == '\n') length = i + 1;
                if (length) { response.assign((const char *)bytes, length); return {}; }
                if (complete && !error) return {karing::ErrorCode::JSONParseError, "Stream ended without a complete record"};
            }
            if (!complete || error.code == NSURLErrorTimedOut) return {karing::ErrorCode::Timeout, "No complete response within sampling deadline"};
            if (error) return {karing::ErrorCode::NetworkError, "HTTP transport failed"};
            response.assign(data.length ? (const char *)data.bytes : "", data.length);
            return {};
        }
    }
};

@implementation TVKaringClient {
    std::unique_ptr<karing::Client> _client;
    std::mutex _mutex;
}

+ (instancetype)clientWithDeviceSettings {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *override = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/ZXTouch/config/tweak/karing.plist"];
    NSString *secret = [override[@"secret"] isKindOfClass:NSString.class] ? override[@"secret"] : nil;
    NSInteger port = 3057;
    NSMutableArray<NSString *> *containers = [NSMutableArray array];
    NSURL *group = [files containerURLForSecurityApplicationGroupIdentifier:@"group.com.nebula.karing"];
    if (group) [containers addObject:group.path];
    // The daemon lacks App Group entitlement. Identify only Karing's container.
    for (NSString *root in @[@"/var/mobile/Containers/Shared/AppGroup", @"/rootfs/var/mobile/Containers/Shared/AppGroup"]) {
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
    NSString *baseURL = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)port];
    return [[self alloc] initWithBaseURL:baseURL secret:secret ?: @"" timeout:10];
}

- (instancetype)initWithBaseURL:(NSString *)baseURL secret:(NSString *)secret timeout:(NSTimeInterval)timeout {
    if ((self = [super init])) {
        karing::Config config;
        config.baseURL = [baseURL UTF8String];
        config.secret = [secret UTF8String];
        config.timeoutMs = (int)(MAX(0.1, MIN(timeout, 120.0)) * 1000);
        auto httpClient = std::make_unique<FoundationHTTPClient>(config);
        _client = std::make_unique<karing::Client>(config, std::move(httpClient));
    }
    return self;
}

- (BOOL)connected {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::VersionInfo version;
    karing::Error err = _client->getVersion(version);
    return !err.isError();
}

// Helper to convert karing::Error to NSError
static NSError *errorFromKaring(const karing::Error& err, const char *domain) {
    if (!err.isError()) return nil;
    return [NSError errorWithDomain:[NSString stringWithUTF8String:domain]
                               code:(int)err.code
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:err.message.c_str()],
                                      @"httpStatus": @(err.httpStatus)}];
}

static NSArray *stringsToArray(const std::vector<std::string>& strings) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:strings.size()];
    for (const auto& value : strings) [array addObject:[NSString stringWithUTF8String:value.c_str()]];
    return array;
}

// --- System Info ---
- (BOOL)getVersion:(NSDictionary **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::VersionInfo version;
    karing::Error err = _client->getVersion(version);
    if (!err.isError() && out) {
        *out = @{@"version": [NSString stringWithUTF8String:version.version.c_str()],
                 @"meta": @(version.meta), @"premium": @(version.premium)};
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)getTraffic:(NSDictionary **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::TrafficStats traffic;
    karing::Error err = _client->getTraffic(traffic);
    if (!err.isError() && out) {
        *out = @{@"up": @(traffic.up), @"down": @(traffic.down)};
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Config Management ---
- (BOOL)getConfigs:(NSString **)outRawJSON error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::string json;
    karing::Error err = _client->getConfigs(json);
    if (!err.isError() && outRawJSON) {
        *outRawJSON = [NSString stringWithUTF8String:json.c_str()];
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)putConfigsWithJSON:(NSString *)configJSON error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->putConfigs([configJSON UTF8String]);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)patchConfigsWithJSON:(NSString *)patchJSON error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->patchConfigs([patchJSON UTF8String]);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Proxy Groups ---
- (BOOL)getProxies:(NSDictionary<NSString *, id> **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::map<std::string, karing::ProxyGroup> groups;
    karing::Error err = _client->getProxies(groups);
    if (!err.isError() && out) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (const auto& [name, group] : groups) {
            NSMutableDictionary *pg = [NSMutableDictionary dictionary];
            pg[@"type"] = [NSString stringWithUTF8String:group.rawType.c_str()];
            pg[@"now"] = [NSString stringWithUTF8String:group.now.c_str()];
            NSMutableArray *all = [NSMutableArray array];
            for (const auto& node : group.all) {
                [all addObject:[NSString stringWithUTF8String:node.c_str()]];
            }
            pg[@"all"] = all;
            dict[[NSString stringWithUTF8String:name.c_str()]] = pg;
        }
        *out = dict;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)getProxyWithName:(NSString *)name result:(NSDictionary **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::ProxyGroup group;
    karing::Error err = _client->getProxy([name UTF8String], group);
    if (!err.isError() && out) {
        *out = @{@"type": [NSString stringWithUTF8String:group.rawType.c_str()],
                 @"now": [NSString stringWithUTF8String:group.now.c_str()],
                 @"all": stringsToArray(group.all)};
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)putProxyGroup:(NSString *)groupName selectNode:(NSString *)nodeName error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->putProxy([groupName UTF8String], [nodeName UTF8String]);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)testProxyDelay:(NSString *)nodeName delayMs:(NSInteger *)outDelayMs error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    int delay = 0;
    karing::Error err = _client->getProxyDelay([nodeName UTF8String], delay);
    if (!err.isError() && outDelayMs) *outDelayMs = delay;
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Connections ---
- (BOOL)getConnections:(NSArray<id> **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<karing::Connection> conns;
    karing::Error err = _client->getConnections(conns);
    if (!err.isError() && out) {
        NSMutableArray *array = [NSMutableArray array];
        for (const auto& c : conns) {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            dict[@"id"] = [NSString stringWithUTF8String:c.id.c_str()];
            dict[@"network"] = [NSString stringWithUTF8String:c.network.c_str()];
            dict[@"source"] = [NSString stringWithUTF8String:c.source.c_str()];
            dict[@"destination"] = [NSString stringWithUTF8String:c.destination.c_str()];
            dict[@"host"] = [NSString stringWithUTF8String:c.host.c_str()];
            dict[@"process"] = [NSString stringWithUTF8String:c.process.c_str()];
            dict[@"upload"] = @(c.upload);
            dict[@"download"] = @(c.download);
            dict[@"startTime"] = [NSString stringWithUTF8String:c.startTime.c_str()];
            NSMutableArray *chains = [NSMutableArray array];
            for (const auto& chain : c.chains) {
                [chains addObject:[NSString stringWithUTF8String:chain.c_str()]];
            }
            dict[@"chains"] = chains;
            [array addObject:dict];
        }
        *out = array;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)deleteAllConnections:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->deleteConnections();
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)deleteConnectionWithID:(NSString *)id error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->deleteConnection([id UTF8String]);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Rules ---
- (BOOL)getRules:(NSArray<id> **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<karing::Rule> rules;
    karing::Error err = _client->getRules(rules);
    if (!err.isError() && out) {
        NSMutableArray *array = [NSMutableArray array];
        for (const auto& r : rules) {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            dict[@"type"] = [NSString stringWithUTF8String:r.type.c_str()];
            dict[@"payload"] = [NSString stringWithUTF8String:r.payload.c_str()];
            dict[@"proxy"] = [NSString stringWithUTF8String:r.proxy.c_str()];
            dict[@"hits"] = @(r.hits);
            [array addObject:dict];
        }
        *out = array;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Providers ---
- (BOOL)getProviders:(NSDictionary<NSString *, id> **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::map<std::string, karing::ProviderInfo> providers;
    karing::Error err = _client->getProviders(providers);
    if (!err.isError() && out) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (const auto& [name, info] : providers) {
            NSMutableDictionary *pd = [NSMutableDictionary dictionary];
            pd[@"type"] = [NSString stringWithUTF8String:info.type.c_str()];
            pd[@"vehicle"] = [NSString stringWithUTF8String:info.vehicle.c_str()];
            NSMutableArray *nodes = [NSMutableArray array];
            for (const auto& node : info.nodes) {
                NSMutableDictionary *nd = [NSMutableDictionary dictionary];
                nd[@"name"] = [NSString stringWithUTF8String:node.name.c_str()];
                nd[@"type"] = [NSString stringWithUTF8String:node.type.c_str()];
                nd[@"server"] = [NSString stringWithUTF8String:node.server.c_str()];
                nd[@"port"] = @(node.port);
                nd[@"proxyGroup"] = [NSString stringWithUTF8String:node.proxyGroup.c_str()];
                nd[@"alive"] = @(node.alive);
                nd[@"delay"] = @(node.delay);
                [nodes addObject:nd];
            }
            pd[@"nodes"] = nodes;
            dict[[NSString stringWithUTF8String:name.c_str()]] = pd;
        }
        *out = dict;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)getProviderWithName:(NSString *)name result:(NSDictionary **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::ProviderInfo info;
    karing::Error err = _client->getProvider([name UTF8String], info);
    if (!err.isError() && out) {
        NSMutableDictionary *pd = [NSMutableDictionary dictionary];
        pd[@"type"] = [NSString stringWithUTF8String:info.type.c_str()];
        pd[@"vehicle"] = [NSString stringWithUTF8String:info.vehicle.c_str()];
        NSMutableArray *nodes = [NSMutableArray array];
        for (const auto& node : info.nodes) {
            NSMutableDictionary *nd = [NSMutableDictionary dictionary];
            nd[@"name"] = [NSString stringWithUTF8String:node.name.c_str()];
            nd[@"type"] = [NSString stringWithUTF8String:node.type.c_str()];
            nd[@"server"] = [NSString stringWithUTF8String:node.server.c_str()];
            nd[@"port"] = @(node.port);
            nd[@"proxyGroup"] = [NSString stringWithUTF8String:node.proxyGroup.c_str()];
            nd[@"alive"] = @(node.alive);
            nd[@"delay"] = @(node.delay);
            [nodes addObject:nd];
        }
        pd[@"nodes"] = nodes;
        *out = pd;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)putProvider:(NSString *)providerName selectNode:(NSString *)nodeName error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::Error err = _client->putProvider([providerName UTF8String], [nodeName UTF8String]);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

- (BOOL)getProviderHealthCheck:(NSString *)name delays:(NSDictionary<NSString *, NSNumber *> **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::map<std::string, int> delaysMap;
    karing::Error err = _client->getProviderHealthCheck([name UTF8String], delaysMap);
    if (!err.isError() && out) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (const auto& [node, delay] : delaysMap) {
            dict[[NSString stringWithUTF8String:node.c_str()]] = @(delay);
        }
        *out = dict;
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- DNS ---
- (BOOL)queryDNSName:(NSString *)name type:(NSString *)type result:(NSDictionary **)out error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    karing::DNSQueryResult result_;
    karing::Error err = _client->queryDNS([name UTF8String], [type UTF8String], result_);
    if (!err.isError() && out) {
        *out = @{@"name": [NSString stringWithUTF8String:result_.name.c_str()],
                 @"type": [NSString stringWithUTF8String:result_.type.c_str()],
                 @"ttl": @(result_.ttl),
                 @"answers": stringsToArray(result_.answers)};
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Logs ---
- (BOOL)getLogs:(NSString **)outRawText lines:(NSInteger)lines error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::string text;
    karing::Error err = _client->getLogs(text, lines);
    if (!err.isError() && outRawText) {
        *outRawText = [NSString stringWithUTF8String:text.c_str()];
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- High-level Fault Tolerance ---
- (BOOL)testAndFailoverGroup:(NSString *)groupName
                    thresholdMs:(NSInteger)thresholdMs
                  maxFailCount:(NSInteger)maxFailCount
                  switchedToNode:(NSString **)switchedToNode
                         error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    std::string switchedTo;
    karing::Error err = _client->testAndFailover([groupName UTF8String], thresholdMs, maxFailCount, &switchedTo);
    if (!err.isError() && switchedToNode && !switchedTo.empty()) {
        *switchedToNode = [NSString stringWithUTF8String:switchedTo.c_str()];
    }
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

// --- Convenience ---
- (BOOL)setRoutingMode:(NSString *)mode error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    if (![mode isEqualToString:@"rule"] && ![mode isEqualToString:@"global"] && ![mode isEqualToString:@"direct"]) {
        if (error) *error = [NSError errorWithDomain:@"TVKaringClient" code:(int)karing::ErrorCode::InvalidArgument userInfo:@{NSLocalizedDescriptionKey: @"Invalid mode: must be 'rule', 'global', or 'direct'"}];
        return NO;
    }
    std::string patch = "{\"mode\": \"" + std::string([mode UTF8String]) + "\"}";
    karing::Error err = _client->patchConfigs(patch);
    if (error) *error = errorFromKaring(err, "TVKaringClient");
    return !err.isError();
}

@end
