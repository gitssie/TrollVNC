// SPDX-License-Identifier: GPL-2.0-only
#include "ZXTouchImage.hpp"
#include <algorithm>
#include <cmath>

namespace zxtouch {
static bool valid(const GrayImage &image) {
    return image.width > 0 && image.height > 0 &&
        image.width <= 16384 && image.height <= 16384 &&
        image.pixels.size() == std::size_t(image.width) * image.height;
}
double correlation(const GrayImage &screen, const GrayImage &pattern, int x, int y, int step) {
    if (!valid(screen) || !valid(pattern) || step < 1 || x < 0 || y < 0 ||
        pattern.width > screen.width - x || pattern.height > screen.height - y) return -1;
    double a = 0, b = 0, aa = 0, bb = 0, ab = 0, difference = 0;
    int n = 0;
    for (int py = 0; py < pattern.height; py += step) {
        for (int px = 0; px < pattern.width; px += step) {
            double av = screen.pixels[std::size_t(y + py) * screen.width + x + px];
            double bv = pattern.pixels[std::size_t(py) * pattern.width + px];
            a += av; b += bv; aa += av * av; bb += bv * bv; ab += av * bv;
            difference += std::abs(av - bv); ++n;
        }
    }
    double variance = (aa - a * a / n) * (bb - b * b / n);
    if (variance <= 1e-8) return 1 - difference / (255 * n);
    return (ab - a * b / n) / std::sqrt(variance);
}
std::vector<Match> matchCandidates(const GrayImage &screen, const GrayImage &pattern) {
    std::vector<Match> best;
    if (!valid(screen) || !valid(pattern) || screen.width > 512 || screen.height > 2048) return best;
    int step = std::max(1, int(std::ceil(std::sqrt(double(pattern.width) * pattern.height / 256))));
    for (int y = 0; y <= screen.height - pattern.height; ++y) {
        for (int x = 0; x <= screen.width - pattern.width; ++x) {
            double score = correlation(screen, pattern, x, y, step);
            if (best.size() == 8 && score <= best.back().score) continue;
            best.push_back({x, y, score});
            std::sort(best.begin(), best.end(), [](const Match &a, const Match &b) { return a.score > b.score; });
            if (best.size() > 8) best.pop_back();
        }
    }
    return best;
}
}
