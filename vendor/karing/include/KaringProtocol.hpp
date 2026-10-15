// SPDX-License-Identifier: GPL-2.0-only
// Karing REST API client protocol for TrollVNC - C++ core types
// This header contains C++ types and should ONLY be included in .mm/.cpp files

#pragma once
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>
#include <optional>
#include <map>
#include <memory>
#include <cstdint>
#include <utility>

namespace karing {

// Error codes
enum class ErrorCode : int {
    OK = 0,
    InvalidArgument = -1,
    NetworkError = -2,
    HTTPError = -3,
    JSONParseError = -4,
    AuthError = -5,
    Timeout = -6,
    NotConnected = -7,
    Unsupported = -8,
    ResultMismatch = -9
};

struct Error {
    ErrorCode code = ErrorCode::OK;
    std::string message;
    int httpStatus = 0;
    Error(ErrorCode value = ErrorCode::OK, std::string detail = {}, int status = 0)
        : code(value), message(std::move(detail)), httpStatus(status) {}
    bool isError() const { return code != ErrorCode::OK; }
};

// Proxy group types (Clash/Mihomo/Karing compatible)
enum class ProxyGroupType {
    Selector,      // Manual selection
    URLTest,       // Auto select by latency
    Fallback,      // Failover in order
    LoadBalance,   // Load balancing
    Unknown
};

struct ProxyNode {
    std::string name;
    bool alive = false;
    int delay = 0;  // ms, 0 = timeout/failed
};

struct ProxyGroup {
    std::string name;
    ProxyGroupType type = ProxyGroupType::Unknown;
    std::string rawType;
    bool synthetic = false;
    std::string now;           // Currently selected node
    std::vector<std::string> all;  // All available nodes
};

struct TrafficStats {
    uint64_t up = 0;
    uint64_t down = 0;
};

struct Connection {
    std::string id;
    std::string network;       // "tcp" | "udp"
    std::string source;
    std::string destination;
    std::string host;
    std::string process;
    uint64_t upload = 0;
    uint64_t download = 0;
    std::string startTime;
    std::vector<std::string> chains;  // Proxy group chain
};

struct Rule {
    std::string type;
    std::string payload;
    std::string proxy;
    uint64_t hits = 0;
};

struct ProviderNode {
    std::string name;
    std::string type;
    std::string server;
    int port = 0;
    std::string proxyGroup;
    bool alive = false;
    int delay = 0;
};

struct ProviderInfo {
    std::string name;
    std::string type;
    std::string vehicle;
    std::vector<ProviderNode> nodes;
};

struct DNSQueryResult {
    std::string name;
    std::string type;
    std::vector<std::string> answers;
    int ttl = 0;
};

struct VersionInfo {
    std::string version;
    bool meta = false;
    bool premium = false;
};

// Base URL and auth
struct Config {
    std::string baseURL = "http://127.0.0.1:3057";
    std::string secret;  // Bearer token
    int timeoutMs = 10000;
};

// HTTP client interface (implemented in platform-specific code)
class IHTTPClient {
public:
    virtual ~IHTTPClient() = default;
    virtual Error request(const std::string& method,
                          const std::string& path,
                          const std::string& body,
                          std::string& response,
                          int& httpStatus) = 0;
};

// Main Karing API client
class Client {
public:
    explicit Client(const Config& config, std::unique_ptr<IHTTPClient> httpClient);
    ~Client();

    // System info
    Error getVersion(VersionInfo& out);
    Error getTraffic(TrafficStats& out);

    // Config management
    Error getConfigs(std::string& outRawJSON);
    Error putConfigs(const std::string& configJSON);
    Error patchConfigs(const std::string& patchJSON);  // e.g. {"mode": "global"}

    // Proxy groups / nodes
    Error getProxies(std::map<std::string, ProxyGroup>& out);
    Error getProxy(const std::string& name, ProxyGroup& out);
    Error putProxy(const std::string& groupName, const std::string& nodeName);  // Only real Selector groups are writable
    Error getProxyDelay(const std::string& nodeName, int& outDelayMs);

    // Connections
    Error getConnections(std::vector<Connection>& out);
    Error deleteConnections();  // Close all
    Error deleteConnection(const std::string& id);

    // Rules
    Error getRules(std::vector<Rule>& out);

    // Providers
    Error getProviders(std::map<std::string, ProviderInfo>& out);
    Error getProvider(const std::string& name, ProviderInfo& out);
    Error putProvider(const std::string& providerName, const std::string& nodeName);
    Error getProviderHealthCheck(const std::string& name, std::map<std::string, int>& outDelays);

    // DNS
    Error queryDNS(const std::string& name, const std::string& type, DNSQueryResult& out);

    // Logs (streaming not supported in this simple client)
    Error getLogs(std::string& outRawText, int lines = 100);

    // High-level fault tolerance helpers
    Error testAndFailover(const std::string& groupName,
                          int thresholdMs = 300,
                          int maxFailCount = 2,
                          std::string* switchedTo = nullptr);

private:
    Config config_;
    std::unique_ptr<IHTTPClient> http_;
    std::string buildURL(const std::string& path) const;
    Error doRequest(const std::string& method,
                    const std::string& path,
                    const std::string& body,
                    std::string& response,
                    int& httpStatus);
    Error parseError(int httpStatus, const std::string& response);
};

// Utility functions
std::string urlEncode(const std::string& value);
ProxyGroupType parseProxyGroupType(const std::string& typeStr);
std::string proxyGroupTypeToString(ProxyGroupType type);

} // namespace karing
