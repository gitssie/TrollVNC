// SPDX-License-Identifier: GPL-2.0-only
// Independently implemented ZXTouch wire protocol for TrollVNC.
#pragma once
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace zxtouch {
constexpr std::size_t maximumCommandBytes = 1024 * 1024;
struct Touch { int type; int finger; double x; double y; };
struct Command {
    int task = 0;
    std::string payload;
    std::vector<std::string> fields;
    std::vector<Touch> touches;
};
// Commands exclude CRLF. Task 10 is fire-and-forget, including malformed touches.
bool parse(std::string_view line, Command &command, std::string &error);
bool number(std::string_view value, double &result);
bool integer(std::string_view value, int &result);
std::vector<std::string> split(std::string_view value, std::string_view delimiter);
class Framer {
    std::string pending;
public:
    bool append(const char *bytes, std::size_t count);
    bool next(std::string &line);
};
}
