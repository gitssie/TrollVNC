// SPDX-License-Identifier: GPL-2.0-only
#include "ZXTouchProtocol.hpp"
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cerrno>
#include <limits>

namespace zxtouch {
std::vector<std::string> split(std::string_view value, std::string_view delimiter) {
    std::vector<std::string> fields;
    std::size_t start = 0, end;
    while ((end = value.find(delimiter, start)) != std::string_view::npos) {
        fields.emplace_back(value.substr(start, end - start));
        start = end + delimiter.size();
    }
    fields.emplace_back(value.substr(start));
    return fields;
}
bool number(std::string_view value, double &result) {
    if (value.empty() || value.find_first_of(" \t\r\n\0", 0, 5) != std::string_view::npos) return false;
    std::string text(value);
    char *end = nullptr;
    errno = 0;
    result = std::strtod(text.c_str(), &end);
    return end == text.c_str() + text.size() && errno != ERANGE && std::isfinite(result);
}
bool integer(std::string_view value, int &result) {
    auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    return !value.empty() && parsed.ec == std::errc{} && parsed.ptr == value.data() + value.size();
}
bool parse(std::string_view line, Command &command, std::string &error) {
    command = {};
    error = "Invalid ZXTouch command";
    if (line.size() < 2 || line.size() > maximumCommandBytes ||
        line.find_first_of("\r\n\0", 0, 3) != std::string_view::npos ||
        line[0] < '0' || line[0] > '9' || line[1] < '0' || line[1] > '9') return false;
    command.task = (line[0] - '0') * 10 + line[1] - '0';
    command.payload = std::string(line.substr(2));
    // Commands have at most twelve fields. Bound parsing allocations before
    // constructing the field vector for an untrusted network payload.
    std::size_t position = 0, fieldCount = 1;
    while ((position = command.payload.find(";;", position)) != std::string::npos) {
        if (++fieldCount > 32) return false;
        position += 2;
    }
    command.fields = split(command.payload, ";;");
    if (command.task != 10) return true;
    error = "Invalid touch packet";
    auto data = line.substr(2);
    if (data.empty() || data[0] < '1' || data[0] > '9') return false;
    std::size_t count = data[0] - '0';
    if (data.size() != 1 + count * 13) return false;
    bool fingers[20] = {};
    for (std::size_t i = 0; i < count; ++i) {
        auto event = data.substr(1 + i * 13, 13);
        for (char c : event) if (c < '0' || c > '9') return false;
        int type = event[0] - '0', finger, x, y;
        if (!integer(event.substr(1, 2), finger) || !integer(event.substr(3, 5), x) ||
            !integer(event.substr(8, 5), y) || type > 2 || finger > 19 || fingers[finger]) return false;
        fingers[finger] = true;
        command.touches.push_back({type, finger, x / 10.0, y / 10.0});
    }
    return true;
}
bool Framer::append(const char *bytes, std::size_t count) {
    // Allow one transport read beyond a full command: its CRLF and the next
    // command may arrive together. A single unterminated line remains bounded.
    constexpr std::size_t maximumBufferedBytes = maximumCommandBytes + 4096 + 2;
    if (count > maximumBufferedBytes || pending.size() > maximumBufferedBytes - count) return false;
    pending.append(bytes, count);
    auto end = pending.find("\r\n");
    return end == std::string::npos ? pending.size() <= maximumCommandBytes + 1 : end <= maximumCommandBytes;
}
bool Framer::next(std::string &line) {
    auto end = pending.find("\r\n");
    if (end == std::string::npos) return false;
    line = pending.substr(0, end);
    pending.erase(0, end + 2);
    return true;
}
}
