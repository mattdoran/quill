// Minimal shim for api/audio/audio_frame.h
// Provides constants needed by AGC2.
#ifndef API_AUDIO_AUDIO_FRAME_H_
#define API_AUDIO_AUDIO_FRAME_H_

#include <cstddef>

namespace webrtc {
constexpr size_t kDefaultAudioBuffersPerSec = 100;
}  // namespace webrtc

#endif  // API_AUDIO_AUDIO_FRAME_H_
