#include "ZXTouchProtocol.hpp"
#include "ZXTouchImage.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <random>

int main() {
    using namespace zxtouch;
    Framer framer;
    std::string line, error;
    Command command;
    assert(framer.append("251\r", 4));
    assert(!framer.next(line));
    assert(framer.append("\n30\r\n", 5));
    assert(framer.next(line) && line == "251");
    assert(parse(line, command, error) && command.task == 25 && command.fields[0] == "1");
    assert(framer.next(line) && line == "30");
    assert(!framer.next(line));
    assert(parse("1011030123405678", command, error));
    assert(command.touches.size() == 1 && command.touches[0].finger == 3);
    assert(command.touches[0].x == 123.4 && command.touches[0].y == 567.8);
    assert(parse(std::string("102") + "1" + "00" + "00010" + "00020" + "0" + "01" + "00030" + "00040", command, error));
    assert(command.touches.size() == 2 && command.touches[1].type == 0);
    assert(!parse("1011990000100001", command, error)); // finger 99
    assert(!parse("1013000000100001", command, error)); // type 3
    assert(!parse(std::string("102") + "1" + "00" + "00010" + "00020" + "0" + "00" + "00030" + "00040", command, error)); // duplicate finger
    assert(!parse("101100000010000", command, error)); // truncated
    assert(!parse("10", command, error) && command.task == 10);
    assert(!parse("a1", command, error));
    assert(!parse("25" + std::string(100, ';'), command, error));
    assert(!parse(std::string("241;;a\0b", 8), command, error));
    assert(parse("271;;0,,0,,0,,0;;;;;;0;;;;0;;", command, error));
    assert(command.fields.size() == 8 && command.fields.back().empty());
    double value;
    int integerValue;
    for (auto invalid : {"nan", "inf", "1junk", " 1", "", "1e999"}) assert(!number(invalid, value));
    assert(number("-1.5", value) && value == -1.5);
    assert(!integer("123x", integerValue));
    Framer oversized;
    std::string huge(maximumCommandBytes + 3, 'x');
    assert(!oversized.append(huge.data(), huge.size()));

    Framer boundary;
    std::string full = "25" + std::string(maximumCommandBytes - 2, 'x');
    assert(boundary.append(full.data(), full.size()));
    assert(boundary.append("\r\n30\r\n", 6));
    assert(boundary.next(line) && line.size() == maximumCommandBytes);
    assert(boundary.next(line) && line == "30");

    GrayImage screen{40, 30, std::vector<uint8_t>(40 * 30)};
    std::mt19937 random(9);
    for (auto &pixel : screen.pixels) pixel = random() % 256;
    GrayImage pattern{7, 5, std::vector<uint8_t>(7 * 5)};
    for (int y = 0; y < 5; ++y) for (int x = 0; x < 7; ++x)
        pattern.pixels[y * 7 + x] = screen.pixels[(y + 13) * 40 + x + 23];
    auto matches = matchCandidates(screen, pattern);
    assert(!matches.empty() && matches[0].x == 23 && matches[0].y == 13);
    assert(std::abs(matches[0].score - 1) < 1e-9);
    assert(correlation(screen, pattern, -1, 0) == -1);
    assert(correlation(screen, pattern, 39, 29) == -1);
    assert(matchCandidates({}, pattern).empty());
    GrayImage constant{2, 2, {50,50,50,50}};
    assert(correlation(constant, constant, 0, 0) == 1);
    std::cout << "ZXTouch protocol and image tests passed\n";
}
