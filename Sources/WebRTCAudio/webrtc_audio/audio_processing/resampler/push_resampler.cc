/*
 *  Copyright (c) 2013 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "audio_processing/agc2/compat.h"

#include "audio_processing/resampler/push_resampler.h"

#include <cstdint>
#include <cstring>
#include <memory>

#include "api/audio/audio_view.h"
#include "audio_processing/include/audio_util.h"
#include "audio_processing/resampler/push_sinc_resampler.h"
#include "rtc_base/checks.h"

namespace webrtc {

namespace {
// Maximum concurrent number of channels for `PushResampler<>`.
// Note that this may be different from what the maximum is for audio codecs.
constexpr int kMaxNumberOfChannels = 8;
}  // namespace

template <typename T>
PushResampler<T>::PushResampler() = default;

template <typename T>
PushResampler<T>::PushResampler(size_t src_samples_per_channel,
                                size_t dst_samples_per_channel,
                                size_t num_channels) {
  EnsureInitialized(src_samples_per_channel, dst_samples_per_channel,
                    num_channels);
}

template <typename T>
PushResampler<T>::~PushResampler() = default;

template <typename T>
void PushResampler<T>::EnsureInitialized(size_t src_samples_per_channel,
                                         size_t dst_samples_per_channel,
                                         size_t num_channels) {
  RTC_DCHECK_GT(src_samples_per_channel, 0);
  RTC_DCHECK_GT(dst_samples_per_channel, 0);
  RTC_DCHECK_GT(num_channels, 0);
  
  
  RTC_DCHECK_LE(num_channels, kMaxNumberOfChannels);

  if (src_samples_per_channel == source_view_.samples_per_channel() &&
      dst_samples_per_channel == destination_view_.samples_per_channel() &&
      num_channels == source_view_.num_channels()) {
    // No-op if settings haven't changed.
    return;
  }

  // Allocate two buffers for all source and destination channels.
  // Then organize source and destination views together with an array of
  // resamplers for each channel in the deinterlaved buffers.
  source_.reset(new T[src_samples_per_channel * num_channels]);
  destination_.reset(new T[dst_samples_per_channel * num_channels]);
  source_view_ = DeinterleavedView<T>(source_.get(), src_samples_per_channel,
                                      num_channels);
  destination_view_ = DeinterleavedView<T>(
      destination_.get(), dst_samples_per_channel, num_channels);
  resamplers_.resize(num_channels);
  for (size_t i = 0; i < num_channels; ++i) {
    resamplers_[i] = std::make_unique<PushSincResampler>(
        src_samples_per_channel, dst_samples_per_channel);
  }
}

template <typename T>
void PushResampler<T>::Resample(MonoView<const T> src, MonoView<T> dst) {
  RTC_DCHECK_EQ(resamplers_.size(), 1);
  RTC_DCHECK_EQ(src.size(), source_view_.samples_per_channel());
  RTC_DCHECK_EQ(dst.size(), destination_view_.samples_per_channel());

  if (src.size() == dst.size()) {
    std::memcpy(dst.data(), src.data(), src.size() * sizeof(T));
  } else {
    resamplers_[0]->Resample(src.data(), src.size(), dst.data(), dst.size());
  }
}

// Explictly generate required instantiations.
template class PushResampler<int16_t>;
template class PushResampler<float>;

}  // namespace webrtc
