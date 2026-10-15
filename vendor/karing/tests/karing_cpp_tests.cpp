// SPDX-License-Identifier: GPL-2.0-only
// Tests link the real production implementation; only HTTP is replaced.
#include "KaringProtocol.hpp"
#include <json/json.h>
#include <cassert>
#include <iostream>
using namespace karing;

class HTTP final : public IHTTPClient {
public:
    std::string mode = "Rule", selected = "A", overrideBody;
    bool noop = false, auth = false, failCurrent = false;
    int writes = 0;
    Error request(const std::string& method, const std::string& url, const std::string& body,
                  std::string& response, int& status) override {
        std::string path = url.substr(std::string("http://test").size());
        status = 200;
        if (auth) { status = 401; response = R"({"message":"Unauthorized"})"; return {}; }
        if (!overrideBody.empty()) { response = overrideBody; return {}; }
        if (path == "/version") response = R"({"version":"sing-box test","meta":true,"premium":true})";
        else if (path == "/traffic") response = R"({"up":12,"down":34})";
        else if (path == "/configs") {
            if (method == "PATCH") { ++writes; if (!noop) mode = body.find("Global") != std::string::npos ? "Global" : "Rule"; status = 204; response.clear(); }
            else response = "{\"mode\":\"" + mode + "\",\"mode-list\":[\"Rule\",\"Global\"]}";
        } else if (path == "/proxies") response = R"({"proxies":{"GLOBAL":{"type":"Selector","now":"A","all":["A","B"]}}})";
        else if (path == "/proxies/Select") {
            if (method == "PUT") { ++writes; if (!noop) selected = "B"; status = 204; response.clear(); }
            else response = "{\"type\":\"Selector\",\"now\":\"" + selected + "\",\"all\":[\"A\",\"B\"]}";
        } else if (path == "/proxies/Auto") response = R"({"type":"URLTest","now":"A","all":["A","B"]})";
        else if (path.find("/delay?") != std::string::npos) {
            assert(path.find("url=https%3A") != std::string::npos && path.find("timeout=") != std::string::npos);
            if (failCurrent && path.find("/A/") != std::string::npos) { status = 408; response = "{}"; }
            else response = R"({"delay":123})";
        } else if (path == "/connections") response = R"({"connections":[{"id":"1","metadata":{"network":"tcp","sourceIP":"10.0.0.1","sourcePort":"42","destinationIP":"1.2.3.4","destinationPort":"443","host":"example.com","processPath":"app"},"upload":12,"download":34,"start":"time","chains":["A"]}]})";
        else if (path == "/rules") response = R"({"rules":[{"type":"default","payload":"test","proxy":"A"}]})";
        else if (path == "/providers/proxies") response = R"({"providers":{}})";
        else if (path.find("/dns/query?") == 0) response = R"({"Status":0,"Question":[{"Name":"example.com.","Qtype":1}],"Answer":[{"data":"1.2.3.4","TTL":100},{"data":"5.6.7.8","TTL":50}]})";
        else { status = 404; response = "{}"; }
        return {};
    }
};
int main() {
    auto http = std::make_unique<HTTP>(); auto *h = http.get();
    Client client({"http://test", "not-a-real-secret", 1000}, std::move(http));
    assert(urlEncode("a/b 空") == "a%2Fb%20%E7%A9%BA");
    VersionInfo version; assert(!client.getVersion(version).isError() && version.meta && version.premium);
    TrafficStats traffic; assert(!client.getTraffic(traffic).isError() && traffic.up == 12 && traffic.down == 34);
    std::map<std::string, ProxyGroup> groups; assert(!client.getProxies(groups).isError() && groups.size() == 1);
    ProxyGroup group; assert(!client.getProxy("GLOBAL", group).isError() && group.now == "A");
    assert(client.putProxy("GLOBAL", "B").code == ErrorCode::Unsupported);
    assert(client.putProxy("Auto", "B").code == ErrorCode::Unsupported);
    assert(client.putProxy("Select", "missing").code == ErrorCode::InvalidArgument);
    assert(!client.putProxy("Select", "B").isError() && h->selected == "B");
    int delay = 0; assert(!client.getProxyDelay("A", delay).isError() && delay == 123);
    std::vector<Connection> conns; assert(!client.getConnections(conns).isError() && conns.size() == 1);
    assert(conns[0].source == "10.0.0.1:42" && conns[0].destination == "1.2.3.4:443" && conns[0].startTime == "time");
    assert(!client.getConnections(conns).isError() && conns.size() == 1);
    std::vector<Rule> rules; assert(!client.getRules(rules).isError() && rules.size() == 1 && rules[0].hits == 0);
    DNSQueryResult dns; assert(!client.queryDNS("example.com", "A", dns).isError() && dns.answers.size() == 2 && dns.ttl == 50);
    std::map<std::string, ProviderInfo> providers; assert(!client.getProviders(providers).isError() && providers.empty());
    std::map<std::string, int> delays; assert(client.getProviderHealthCheck("x", delays).code == ErrorCode::Unsupported);
    assert(client.putProvider("x", "y").code == ErrorCode::Unsupported);
    assert(client.putConfigs("{}").code == ErrorCode::Unsupported);
    assert(client.patchConfigs(R"({"mode":"direct"})").code == ErrorCode::Unsupported);
    assert(!client.patchConfigs(R"({"mode":"global"})").isError() && h->mode == "Global");
    assert(client.patchConfigs(R"({"log-level":"debug"})").code == ErrorCode::InvalidArgument);
    h->noop = true; h->mode = "Rule"; assert(client.patchConfigs(R"({"mode":"global"})").code == ErrorCode::ResultMismatch);
    h->selected = "A"; assert(client.putProxy("Select", "B").code == ErrorCode::ResultMismatch);
    h->noop = false; h->failCurrent = true; std::string switched;
    assert(!client.testAndFailover("Select", 300, 1, &switched).isError() && switched == "B");
    assert(client.testAndFailover("Auto").code == ErrorCode::Unsupported);
    h->auth = true; assert(client.getVersion(version).code == ErrorCode::AuthError);
    assert(client.testAndFailover("Select").code == ErrorCode::AuthError); h->auth = false;
    h->overrideBody = "[]"; assert(client.getConnections(conns).code == ErrorCode::OK); // legacy array form
    h->overrideBody = "{\"connections\":42}"; assert(client.getConnections(conns).code == ErrorCode::JSONParseError);
    h->overrideBody = "{\"version\":42}"; assert(client.getVersion(version).code == ErrorCode::JSONParseError);
    h->overrideBody = "{\"proxies\":false}"; assert(client.getProxies(groups).code == ErrorCode::JSONParseError);
    h->overrideBody = "{\"mode\":\"Rule\"}"; assert(client.patchConfigs(R"({"mode":"global"})").code == ErrorCode::Unsupported);
    ProviderInfo provider; h->overrideBody = "{}"; assert(client.getProvider("x", provider).code == ErrorCode::JSONParseError);
    h->overrideBody = "{\"type\":false}"; assert(client.getProvider("x", provider).code == ErrorCode::JSONParseError);
    h->overrideBody = "{\"Status\":3}"; assert(client.queryDNS("missing", "A", dns).isError());
    std::cout << "Production protocol regression tests passed\n";
}
