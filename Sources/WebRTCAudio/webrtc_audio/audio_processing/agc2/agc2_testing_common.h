// Minimal subset of agc2_testing_common.h - only the constants needed by
// limiter_db_gain_curve.h. The full file depends on rtc_base/random.h which
// we don't need.
#ifndef MODULES_AUDIO_PROCESSING_AGC2_AGC2_TESTING_COMMON_H_
#define MODULES_AUDIO_PROCESSING_AGC2_AGC2_TESTING_COMMON_H_

namespace webrtc {
namespace test {

constexpr float kLimiterMaxInputLevelDbFs = 1.f;
constexpr float kLimiterKneeSmoothnessDb = 1.f;
constexpr float kLimiterCompressionRatio = 5.f;

}  // namespace test
}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_AGC2_AGC2_TESTING_COMMON_H_
