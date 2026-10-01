// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#include <cstdint>
#include <vector>
namespace zxtouch {
struct GrayImage { int width = 0, height = 0; std::vector<uint8_t> pixels; };
struct Match { int x = -1, y = -1; double score = -1; };
// Coarse NCC candidates; the host verifies/refines them at native resolution.
std::vector<Match> matchCandidates(const GrayImage &screen, const GrayImage &pattern);
double correlation(const GrayImage &screen, const GrayImage &pattern, int x, int y, int sampleStep = 1);
}
