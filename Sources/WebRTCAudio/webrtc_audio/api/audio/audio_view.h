// Minimal shim for api/audio/audio_view.h
// Provides DeinterleavedView and MonoView for AGC2.
#ifndef API_AUDIO_AUDIO_VIEW_H_
#define API_AUDIO_AUDIO_VIEW_H_

#include <cstddef>

#include "rtc_base/checks.h"

namespace webrtc {

template <typename T>
class MonoView {
 public:
  MonoView(T* data, size_t size) : data_(data), size_(size) {}
  T* data() { return data_; }
  const T* data() const { return data_; }
  size_t size() const { return size_; }
  T& operator[](size_t i) { return data_[i]; }
  const T& operator[](size_t i) const { return data_[i]; }
  T* begin() { return data_; }
  T* end() { return data_ + size_; }
  const T* begin() const { return data_; }
  const T* end() const { return data_ + size_; }
  template <size_t N>
  MonoView<T> first() const { return MonoView<T>(data_, N); }
  MonoView<T> subspan(size_t offset, size_t count) const {
    return MonoView<T>(data_ + offset, count);
  }
  MonoView<T> subspan(size_t offset) const {
    return MonoView<T>(data_ + offset, size_ - offset);
  }
 private:
  T* data_;
  size_t size_;
};

// InterleavedView is just a MonoView for our purposes (mono-only usage)
template <typename T>
using InterleavedView = MonoView<T>;

template <typename T>
class DeinterleavedView {
 public:
  DeinterleavedView() : data_(nullptr), samples_per_channel_(0), num_channels_(0) {}
  DeinterleavedView(T* const* data, size_t samples_per_channel, size_t num_channels)
      : data_(data ? *data : nullptr),
        samples_per_channel_(samples_per_channel),
        num_channels_(num_channels) {}
  DeinterleavedView(T* data, size_t samples_per_channel, size_t num_channels)
      : data_(data),
        samples_per_channel_(samples_per_channel),
        num_channels_(num_channels) {}

  size_t num_channels() const { return num_channels_; }
  size_t samples_per_channel() const { return samples_per_channel_; }

  MonoView<T> operator[](size_t channel) {
    RTC_DCHECK_LT(channel, num_channels_);
    return MonoView<T>(data_ + channel * samples_per_channel_, samples_per_channel_);
  }
  MonoView<const T> operator[](size_t channel) const {
    RTC_DCHECK_LT(channel, num_channels_);
    return MonoView<const T>(data_ + channel * samples_per_channel_, samples_per_channel_);
  }

 private:
  T* data_;
  size_t samples_per_channel_;
  size_t num_channels_;
};

}  // namespace webrtc

#endif  // API_AUDIO_AUDIO_VIEW_H_
