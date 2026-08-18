#include "WebRTCAudio.h"

#include <algorithm>
#include <memory>

#include "api/echo_canceller3_config.h"
#include "api/echo_canceller3_factory.h"
#include "api/echo_control.h"
#include "audio_processing/audio_buffer.h"
#include "audio_processing/high_pass_filter.h"

namespace {

constexpr float kInt16Max = 32767.0f;

class EchoCanceller {
public:
    explicit EchoCanceller(int sample_rate)
        : frame_size_(sample_rate / 100),
          near_(sample_rate, 1, sample_rate, 1, sample_rate, 1),
          far_(sample_rate, 1, sample_rate, 1, sample_rate, 1),
          high_pass_(sample_rate, 1) {
        webrtc::EchoCanceller3Config config;
        webrtc::EchoCanceller3Factory factory(config);
        aec_ = factory.Create(sample_rate, 1, 1);
    }

    void process(
        const float *near_audio,
        const float *far_audio,
        float *output,
        int sample_count
    ) {
        for (int offset = 0; offset < sample_count; offset += frame_size_) {
            processFrame(near_audio + offset, far_audio + offset, output + offset);
        }
    }

private:
    void processFrame(const float *near_audio, const float *far_audio, float *output) {
        float *near_channel = near_.channels()[0];
        float *far_channel = far_.channels()[0];
        for (int sample = 0; sample < frame_size_; ++sample) {
            near_channel[sample] = std::clamp(
                near_audio[sample] * kInt16Max, -32768.0f, 32767.0f
            );
            far_channel[sample] = std::clamp(
                far_audio[sample] * kInt16Max, -32768.0f, 32767.0f
            );
        }

        far_.SplitIntoFrequencyBands();
        aec_->AnalyzeRender(&far_);
        far_.MergeFrequencyBands();
        aec_->AnalyzeCapture(&near_);
        near_.SplitIntoFrequencyBands();
        high_pass_.Process(&near_, true);
        aec_->SetAudioBufferDelay(0);
        aec_->ProcessCapture(&near_, nullptr, false);
        near_.MergeFrequencyBands();

        const float *cleaned = near_.channels_const()[0];
        for (int sample = 0; sample < frame_size_; ++sample) {
            output[sample] = cleaned[sample] / kInt16Max;
        }
    }

    int frame_size_;
    std::unique_ptr<webrtc::EchoControl> aec_;
    webrtc::AudioBuffer near_;
    webrtc::AudioBuffer far_;
    webrtc::HighPassFilter high_pass_;
};

}  // namespace

QuillEchoCanceller quill_aec_create(int sample_rate) {
    if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) {
        return nullptr;
    }
    try {
        return new EchoCanceller(sample_rate);
    } catch (...) {
        return nullptr;
    }
}

void quill_aec_destroy(QuillEchoCanceller canceller) {
    delete static_cast<EchoCanceller *>(canceller);
}

int quill_aec_process(
    QuillEchoCanceller canceller,
    const float *near_audio,
    const float *far_audio,
    float *output,
    int sample_count
) {
    if (canceller == nullptr || near_audio == nullptr ||
        far_audio == nullptr || output == nullptr || sample_count <= 0) {
        return 0;
    }
    static_cast<EchoCanceller *>(canceller)->process(
        near_audio, far_audio, output, sample_count
    );
    return 1;
}
