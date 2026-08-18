// Minimal shim for api/audio/audio_processing.h
// Only provides the Config structs needed by AGC2.
#ifndef API_AUDIO_AUDIO_PROCESSING_H_
#define API_AUDIO_AUDIO_PROCESSING_H_

namespace webrtc {

class AudioProcessing {
 public:
  struct Config {
    struct GainController2 {
      struct AdaptiveDigital {
        bool enabled = false;
        float headroom_db = 5.0f;
        float max_gain_db = 50.0f;
        float initial_gain_db = 15.0f;
        float max_gain_change_db_per_second = 6.0f;
        float max_output_noise_level_dbfs = -50.0f;

        bool operator==(const AdaptiveDigital& rhs) const {
          return enabled == rhs.enabled &&
                 headroom_db == rhs.headroom_db &&
                 max_gain_db == rhs.max_gain_db &&
                 initial_gain_db == rhs.initial_gain_db &&
                 max_gain_change_db_per_second == rhs.max_gain_change_db_per_second &&
                 max_output_noise_level_dbfs == rhs.max_output_noise_level_dbfs;
        }
        bool operator!=(const AdaptiveDigital& rhs) const { return !(*this == rhs); }
      } adaptive_digital;

      struct FixedDigital {
        float gain_db = 0.0f;
      } fixed_digital;
    } gain_controller2;
  };
};

}  // namespace webrtc

#endif  // API_AUDIO_AUDIO_PROCESSING_H_
