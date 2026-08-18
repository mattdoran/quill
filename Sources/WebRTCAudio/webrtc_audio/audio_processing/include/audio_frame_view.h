// Minimal shim for modules/audio_processing/include/audio_frame_view.h
#ifndef MODULES_AUDIO_PROCESSING_INCLUDE_AUDIO_FRAME_VIEW_H_
#define MODULES_AUDIO_PROCESSING_INCLUDE_AUDIO_FRAME_VIEW_H_

#include "api/audio/audio_view.h"

namespace webrtc {

template <class T>
class AudioFrameView {
 public:
  AudioFrameView(T* const* audio_samples, int num_channels, int channel_size)
      : view_(audio_samples, channel_size, num_channels) {}

  template <class U>
  explicit AudioFrameView(DeinterleavedView<U> view) : view_(view) {}

  int num_channels() const { return view_.num_channels(); }
  int samples_per_channel() const { return view_.samples_per_channel(); }
  MonoView<T> channel(int idx) { return view_[idx]; }

  DeinterleavedView<T> view() { return view_; }

 private:
  DeinterleavedView<T> view_;
};

}  // namespace webrtc

#endif  // MODULES_AUDIO_PROCESSING_INCLUDE_AUDIO_FRAME_VIEW_H_
