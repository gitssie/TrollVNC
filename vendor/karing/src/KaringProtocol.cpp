// SPDX-License-Identifier: GPL-2.0-only
#include "KaringProtocol.hpp"
#include <algorithm>
#include <cctype>
#include <sstream>
#include <iomanip>
#include <json/json.h>  // Using jsoncpp - available on iOS

namespace karing {

static bool parseJSON(const std::string& text, Json::Value& root, std::string& error) {
    Json::CharReaderBuilder builder;
    builder["failIfExtra"] = true;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    return reader->parse(text.data(), text.data() + text.size(), &root, &error);
}
static Error schemaError(const char *message) { return {ErrorCode::JSONParseError, message}; }
static std::string lower(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
    return text;
}
static std::string text(const Json::Value& v) { return v.isString() ? v.asString() : std::string(); }
static std::string portText(const Json::Value& v) { return v.isString() ? v.asString() : v.isUInt() ? std::to_string(v.asUInt()) : std::string(); }
static bool parseGroup(const std::string& name, const Json::Value& pg, ProxyGroup& group) {
    if (!pg.isObject() || !pg["type"].isString() ||
        (!pg["all"].isNull() && !pg["all"].isArray()) ||
        (!pg["now"].isNull() && !pg["now"].isString())) return false;
    group = {};
    group.name = name;
    group.rawType = pg["type"].asString();
    group.type = parseProxyGroupType(group.rawType);
    group.now = text(pg["now"]);
    for (const auto& node : pg["all"]) {
        if (!node.isString()) return false;
        group.all.push_back(node.asString());
    }
    return true;
}


std::string urlEncode(const std::string& value) {
    std::ostringstream escaped;
    escaped.fill('0');
    escaped << std::hex << std::uppercase;
    for (char c : value) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped << c;
        } else {
            escaped << '%' << std::setw(2) << static_cast<int>(static_cast<unsigned char>(c));
        }
    }
    return escaped.str();
}

ProxyGroupType parseProxyGroupType(const std::string& typeStr) {
    std::string lower = typeStr;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
    if (lower == "selector") return ProxyGroupType::Selector;
    if (lower == "urltest") return ProxyGroupType::URLTest;
    if (lower == "fallback") return ProxyGroupType::Fallback;
    if (lower == "loadbalance") return ProxyGroupType::LoadBalance;
    return ProxyGroupType::Unknown;
}

std::string proxyGroupTypeToString(ProxyGroupType type) {
    switch (type) {
        case ProxyGroupType::Selector: return "Selector";
        case ProxyGroupType::URLTest: return "URLTest";
        case ProxyGroupType::Fallback: return "Fallback";
        case ProxyGroupType::LoadBalance: return "LoadBalance";
        default: return "Unknown";
    }
}

Client::Client(const Config& config, std::unique_ptr<IHTTPClient> httpClient)
    : config_(config), http_(std::move(httpClient)) {}

Client::~Client() = default;

std::string Client::buildURL(const std::string& path) const {
    return config_.baseURL + path;
}

Error Client::doRequest(const std::string& method,
                        const std::string& path,
                        const std::string& body,
                        std::string& response,
                        int& httpStatus) {
    std::string url = buildURL(path);
    Error err = http_->request(method, url, body, response, httpStatus);
    if (err.isError()) return err;
    return parseError(httpStatus, response);
}

Error Client::parseError(int httpStatus, const std::string&) {
    if (httpStatus >= 200 && httpStatus < 300) {
        return Error{ErrorCode::OK, ""};
    }
    Error err;
    err.httpStatus = httpStatus;
    if (httpStatus == 401) {
        err.code = ErrorCode::AuthError;
        err.message = "Authentication failed (401)";
    } else if (httpStatus == 404) {
        err.code = ErrorCode::HTTPError;
        err.message = "Not found (404)";
    } else if (httpStatus >= 500) {
        err.code = ErrorCode::HTTPError;
        err.message = "Server error: " + std::to_string(httpStatus);
    } else {
        err.code = ErrorCode::HTTPError;
        err.message = "HTTP " + std::to_string(httpStatus);
    }
    return err;
}

// --- API Implementations ---

Error Client::getVersion(VersionInfo& out) {
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/version", "", response, httpStatus);
    if (err.isError()) return err;

    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr)) {
        return Error{ErrorCode::JSONParseError, "Failed to parse version: "};
    }
    if (!root.isObject() || !root["version"].isString() ||
        (!root["meta"].isNull() && !root["meta"].isBool()) ||
        (!root["premium"].isNull() && !root["premium"].isBool())) return schemaError("Invalid version schema");
    out.version = root["version"].asString();
    out.meta = root["meta"].asBool();
    out.premium = root["premium"].asBool();
    return Error{ErrorCode::OK};
}

Error Client::getTraffic(TrafficStats& out) {
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/traffic", "", response, httpStatus);
    if (err.isError()) return err;

    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr)) {
        return Error{ErrorCode::JSONParseError, "Failed to parse traffic: "};
    }
    if (!root.isObject() || !root["up"].isUInt64() || !root["down"].isUInt64()) return schemaError("Invalid traffic schema");
    out.up = root["up"].asUInt64();
    out.down = root["down"].asUInt64();
    return Error{ErrorCode::OK};
}

Error Client::getConfigs(std::string& outRawJSON) {
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/configs", "", response, httpStatus);
    if (err.isError()) return err;
    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr) || !root.isObject()) return schemaError("Invalid config JSON");
    outRawJSON = response;
    return Error{ErrorCode::OK};
}

Error Client::putConfigs(const std::string&) {
    // sing-box's PUT /configs is a no-op returning 204, not a reload endpoint.
    return {ErrorCode::Unsupported, "Karing sing-box does not support config reload via PUT /configs"};
}

Error Client::patchConfigs(const std::string& patchJSON) {
    Json::Value patch;
    std::string parseErr;
    if (!parseJSON(patchJSON, patch, parseErr) || !patch.isObject() || patch.size() != 1 ||
        !patch["mode"].isString() || patch["mode"].asString().empty())
        return {ErrorCode::InvalidArgument, "Karing supports only a nonempty mode patch"};
    std::string raw;
    Error err = getConfigs(raw);
    if (err.isError()) return err;
    Json::Value before;
    if (!parseJSON(raw, before, parseErr) || !before["mode"].isString()) return schemaError("Missing config mode");
    const auto wanted = lower(patch["mode"].asString());
    if (!before.isMember("mode-list")) return {ErrorCode::Unsupported, "Karing did not publish routing mode capabilities"};
    if (before.isMember("mode-list")) {
        if (!before["mode-list"].isArray()) return schemaError("Invalid mode-list");
        bool supported = false;
        for (const auto& mode : before["mode-list"]) {
            if (!mode.isString()) return schemaError("Invalid mode-list entry");
            if (lower(mode.asString()) == wanted) { patch["mode"] = mode; supported = true; break; }
        }
        if (!supported) return {ErrorCode::Unsupported, "Requested routing mode is absent from Karing mode-list"};
    }
    if (lower(before["mode"].asString()) == wanted) return {};
    Json::StreamWriterBuilder writer;
    int status = 0;
    err = doRequest("PATCH", "/configs", Json::writeString(writer, patch), raw, status);
    if (err.isError()) return err;
    err = getConfigs(raw);
    if (err.isError()) return err;
    Json::Value after;
    if (!parseJSON(raw, after, parseErr) || !after["mode"].isString()) return schemaError("Missing updated mode");
    if (lower(after["mode"].asString()) != wanted) return {ErrorCode::ResultMismatch, "Karing acknowledged the patch but mode did not change"};
    return {};
}

Error Client::getProxies(std::map<std::string, ProxyGroup>& out) {
    std::string response, parseErr;
    int status = 0;
    Error err = doRequest("GET", "/proxies", "", response, status);
    if (err.isError()) return err;
    Json::Value root;
    if (!parseJSON(response, root, parseErr) || !root.isObject() || !root["proxies"].isObject()) return schemaError("Invalid proxies schema");
    std::map<std::string, ProxyGroup> parsed;
    for (const auto& name : root["proxies"].getMemberNames()) {
        ProxyGroup group;
        if (!parseGroup(name, root["proxies"][name], group)) return schemaError("Invalid proxy entry");
        parsed.emplace(name, std::move(group));
    }
    out = std::move(parsed);
    return {};
}

Error Client::getProxy(const std::string& name, ProxyGroup& out) {
    if (name.empty()) return {ErrorCode::InvalidArgument, "Proxy name is empty"};
    std::string response, parseErr;
    int status = 0;
    Error err = doRequest("GET", "/proxies/" + urlEncode(name), "", response, status);
    // GLOBAL is synthetic in sing-box and only exists in the list response.
    if (err.httpStatus == 404 && name == "GLOBAL") {
        std::map<std::string, ProxyGroup> groups;
        err = getProxies(groups);
        if (err.isError()) return err;
        auto found = groups.find(name);
        if (found == groups.end()) return {ErrorCode::HTTPError, "Proxy not found", 404};
        out = found->second;
        out.synthetic = true;
        return {};
    }
    if (err.isError()) return err;
    Json::Value root;
    if (!parseJSON(response, root, parseErr) || !parseGroup(name, root, out)) return schemaError("Invalid proxy schema");
    return {};
}

Error Client::putProxy(const std::string& groupName, const std::string& nodeName) {
    ProxyGroup group;
    Error err = getProxy(groupName, group);
    if (err.isError()) return err;
    if (group.synthetic || group.type != ProxyGroupType::Selector) return {ErrorCode::Unsupported, "Karing node switching requires a real Selector group"};
    if (nodeName.empty() || std::find(group.all.begin(), group.all.end(), nodeName) == group.all.end())
        return {ErrorCode::InvalidArgument, "Node is absent from the selector group"};
    if (group.now == nodeName) return {};
    Json::Value body;
    body["name"] = nodeName;
    Json::StreamWriterBuilder writer;
    std::string response;
    int status = 0;
    err = doRequest("PUT", "/proxies/" + urlEncode(groupName), Json::writeString(writer, body), response, status);
    if (err.isError()) return err;
    err = getProxy(groupName, group);
    if (err.isError()) return err;
    return group.now == nodeName ? Error{} : Error{ErrorCode::ResultMismatch, "Karing acknowledged switch but selected node did not change"};
}

Error Client::getProxyDelay(const std::string& nodeName, int& outDelayMs) {
    std::string encoded = urlEncode(nodeName);
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/proxies/" + encoded + "/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=" + std::to_string(std::max(1, std::min(config_.timeoutMs - 100, 5000))), "", response, httpStatus);
    if (err.isError()) return err;

    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr)) {
        return Error{ErrorCode::JSONParseError, "Failed to parse delay: "};
    }
    if (!root.isObject() || !root.isMember("delay") || (!root["delay"].isNull() && !root["delay"].isInt())) return schemaError("Invalid delay schema");
    Json::Value delayVal = root["delay"];
    if (delayVal.isNull()) {
        outDelayMs = 0;  // Not testable
    } else {
        outDelayMs = delayVal.asInt();
    }
    return Error{ErrorCode::OK};
}

Error Client::getConnections(std::vector<Connection>& out) {
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/connections", "", response, httpStatus);
    if (err.isError()) return err;

    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr)) {
        return Error{ErrorCode::JSONParseError, "Failed to parse connections: "};
    }

    const Json::Value& list = root.isObject() ? root["connections"] : root;
    if (!list.isArray()) return schemaError("Invalid connections schema");
    std::vector<Connection> parsed;
    for (const auto& conn : list) {
        if (!conn.isObject() || !conn["id"].isString() || !conn["upload"].isUInt64() || !conn["download"].isUInt64()) return schemaError("Invalid connection entry");
        Connection c;
        c.id = conn["id"].asString();
        const auto& meta = conn["metadata"];
        if (!meta.isNull() && !meta.isObject()) return schemaError("Invalid connection metadata");
        c.network = text(meta.isObject() ? meta["network"] : conn["network"]);
        c.source = meta.isObject() ? text(meta["sourceIP"]) + ":" + portText(meta["sourcePort"]) : text(conn["source"]);
        c.destination = meta.isObject() ? text(meta["destinationIP"]) + ":" + portText(meta["destinationPort"]) : text(conn["destination"]);
        c.host = text(meta.isObject() ? meta["host"] : conn["host"]);
        c.process = text(meta.isObject() ? meta["processPath"] : conn["process"]);
        c.upload = conn["upload"].asUInt64();
        c.download = conn["download"].asUInt64();
        c.startTime = text(conn.isMember("start") ? conn["start"] : conn["startTime"]);
        if (!conn["chains"].isNull() && !conn["chains"].isArray()) return schemaError("Invalid connection chains");
        for (const auto& chain : conn["chains"]) {
            if (!chain.isString()) return schemaError("Invalid connection chain");
            c.chains.push_back(chain.asString());
        }
        parsed.push_back(std::move(c));
    }
    out = std::move(parsed);
    return {};
}

Error Client::deleteConnections() {
    std::string response;
    int httpStatus = 0;
    return doRequest("DELETE", "/connections", "", response, httpStatus);
}

Error Client::deleteConnection(const std::string& id) {
    std::string response;
    int httpStatus = 0;
    return doRequest("DELETE", "/connections/" + urlEncode(id), "", response, httpStatus);
}

Error Client::getRules(std::vector<Rule>& out) {
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", "/rules", "", response, httpStatus);
    if (err.isError()) return err;

    Json::Value root;
    std::string parseErr;
    if (!parseJSON(response, root, parseErr)) {
        return Error{ErrorCode::JSONParseError, "Failed to parse rules: "};
    }

    const Json::Value& list = root.isObject() ? root["rules"] : root;
    if (!list.isArray()) return schemaError("Invalid rules schema");
    std::vector<Rule> parsed;
    for (const auto& rule : list) {
        if (!rule.isObject() || !rule["type"].isString() || !rule["payload"].isString() || !rule["proxy"].isString() ||
            (!rule["hits"].isNull() && !rule["hits"].isUInt64())) return schemaError("Invalid rule entry");
        Rule r;
        r.type = rule["type"].asString();
        r.payload = rule["payload"].asString();
        r.proxy = rule["proxy"].asString();
        r.hits = rule["hits"].asUInt64();
        parsed.push_back(std::move(r));
    }
    out = std::move(parsed);
    return {};
}

static bool parseProvider(const std::string& name, const Json::Value& root, ProviderInfo& out) {
    if (!root.isObject() || !root["type"].isString()) return false;
    ProviderInfo parsed;
    parsed.name = name;
    parsed.type = root["type"].asString();
    parsed.vehicle = text(root.isMember("vehicleType") ? root["vehicleType"] : root["vehicle"]);
    const auto& nodes = root.isMember("proxies") ? root["proxies"] : root["nodes"];
    if (!nodes.isArray()) return false;
    for (const auto& node : nodes) {
        if (!node.isObject() || !node["name"].isString() || !node["type"].isString()) return false;
        ProviderNode n;
        n.name = node["name"].asString(); n.type = node["type"].asString();
        n.server = text(node["server"]); n.proxyGroup = text(node["proxyGroup"]);
        if (!node["port"].isNull() && !node["port"].isInt()) return false;
        n.port = node["port"].asInt();
        if (!node["alive"].isNull() && !node["alive"].isBool()) return false;
        n.alive = node["alive"].asBool();
        if (node["delay"].isInt()) n.delay = node["delay"].asInt();
        parsed.nodes.push_back(std::move(n));
    }
    out = std::move(parsed);
    return true;
}
Error Client::getProviders(std::map<std::string, ProviderInfo>& out) {
    std::string response, parseErr;
    int status = 0;
    Error err = doRequest("GET", "/providers/proxies", "", response, status);
    if (err.isError()) return err;
    Json::Value root;
    if (!parseJSON(response, root, parseErr) || !root.isObject() || !root["providers"].isObject()) return schemaError("Invalid providers schema");
    std::map<std::string, ProviderInfo> parsed;
    for (const auto& name : root["providers"].getMemberNames()) {
        ProviderInfo provider;
        if (!parseProvider(name, root["providers"][name], provider)) return schemaError("Invalid provider entry");
        parsed.emplace(name, std::move(provider));
    }
    out = std::move(parsed);
    return {};
}
Error Client::getProvider(const std::string& name, ProviderInfo& out) {
    if (name.empty()) return {ErrorCode::InvalidArgument, "Provider name is empty"};
    std::string response, parseErr;
    int status = 0;
    Error err = doRequest("GET", "/providers/proxies/" + urlEncode(name), "", response, status);
    if (err.isError()) return err;
    if (response.empty()) return {ErrorCode::Unsupported, "Provider detail is not implemented by this backend"};
    Json::Value root;
    if (!parseJSON(response, root, parseErr) || !parseProvider(name, root, out)) return schemaError("Invalid provider schema");
    return {};
}

Error Client::putProvider(const std::string&, const std::string&) {
    return {ErrorCode::Unsupported, "Karing does not expose provider node selection; use a Selector group"};
}

Error Client::getProviderHealthCheck(const std::string&, std::map<std::string, int>&) {
    return {ErrorCode::Unsupported, "Karing sing-box does not implement provider health checks"};
}

Error Client::queryDNS(const std::string& name, const std::string& type, DNSQueryResult& out) {
    if (name.empty()) return {ErrorCode::InvalidArgument, "DNS name is empty"};
    const std::string queryType = type.empty() ? "A" : type;
    std::string response, parseErr;
    int status = 0;
    Error err = doRequest("GET", "/dns/query?name=" + urlEncode(name) + "&type=" + urlEncode(queryType), "", response, status);
    if (err.isError()) return err;
    Json::Value root;
    if (!parseJSON(response, root, parseErr) || !root.isObject() || !root["Status"].isInt() ||
        (!root["Answer"].isNull() && !root["Answer"].isArray())) return schemaError("Invalid DNS schema");
    if (root["Status"].asInt() != 0) return {ErrorCode::HTTPError, "DNS returned rcode " + std::to_string(root["Status"].asInt()), status};
    DNSQueryResult parsed;
    parsed.name = name;
    parsed.type = queryType;
    bool first = true;
    for (const auto& answer : root["Answer"]) {
        if (!answer.isObject() || !answer["data"].isString() || !answer["TTL"].isInt()) return schemaError("Invalid DNS answer");
        parsed.answers.push_back(answer["data"].asString());
        parsed.ttl = first ? answer["TTL"].asInt() : std::min(parsed.ttl, answer["TTL"].asInt());
        first = false;
    }
    out = std::move(parsed);
    return {};
}

Error Client::getLogs(std::string& outRawText, int lines) {
    if (lines < 1 || lines > 1000) return {ErrorCode::InvalidArgument, "Log sample count must be 1..1000"};
    std::string path = "/logs?level=info";
    if (lines > 0) {
        path += "&lines=" + std::to_string(lines);
    }
    std::string response;
    int httpStatus = 0;
    Error err = doRequest("GET", path, "", response, httpStatus);
    if (err.isError()) return err;
    if (response.empty()) return {ErrorCode::Unsupported, "No log stream returned by backend"};
    outRawText = response;
    return Error{ErrorCode::OK};
}

Error Client::testAndFailover(const std::string& groupName,
                              int thresholdMs,
                              int maxFailCount,
                              std::string* switchedTo) {
    if (thresholdMs <= 0 || maxFailCount < 1 || maxFailCount > 10) return {ErrorCode::InvalidArgument, "Invalid failover limits"};
    if (switchedTo) switchedTo->clear();
    // 1. Get current node
    ProxyGroup group;
    Error err = getProxy(groupName, group);
    if (err.isError()) return err;

    if (group.synthetic || group.type != ProxyGroupType::Selector) return {ErrorCode::Unsupported, "Failover requires a manually switchable Selector group"};
    std::string current = group.now;
    if (current.empty()) {
        return Error{ErrorCode::InvalidArgument, "No current node in group"};
    }

    // 2. Test current node
    int delay = 0;
    for (int i = 0; i < maxFailCount; ++i) {
        err = getProxyDelay(current, delay);
        if (err.isError()) {
            if (err.code == ErrorCode::AuthError || err.code == ErrorCode::JSONParseError || (err.httpStatus >= 400 && err.httpStatus < 500 && err.httpStatus != 408)) return err;
            continue;
        }
        if (delay > 0 && delay <= thresholdMs) {
            return Error{ErrorCode::OK};  // Current node is healthy
        }
    }

    // 3. Current node unhealthy, test alternatives
    for (const auto& node : group.all) {
        if (node == current) continue;
        err = getProxyDelay(node, delay);
        if (err.isError()) {
            if (err.code == ErrorCode::AuthError || err.code == ErrorCode::JSONParseError || (err.httpStatus >= 400 && err.httpStatus < 500 && err.httpStatus != 408)) return err;
            continue;
        }
        if (delay > 0 && delay <= thresholdMs) {
            // 4. Switch to this node
            err = putProxy(groupName, node);
            if (!err.isError() && switchedTo) {
                *switchedTo = node;
            }
            return err;
        }
    }

    // 5. All nodes failed
    return Error{ErrorCode::NetworkError, "All nodes in group " + groupName + " are unhealthy"};
}

} // namespace karing
