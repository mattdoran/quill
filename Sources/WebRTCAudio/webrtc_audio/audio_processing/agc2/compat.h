// Compatibility shim: bring rtc:: utilities into webrtc:: namespace
// so upstream AGC2 code compiles against our older vendored tree.
#ifndef AUDIO_PROCESSING_AGC2_COMPAT_H_
#define AUDIO_PROCESSING_AGC2_COMPAT_H_

#include "api/audio/audio_view.h"
#include "rtc_base/numerics/safe_minmax.h"
#include "rtc_base/numerics/safe_compare.h"
#include "rtc_base/numerics/safe_conversions.h"
#include "rtc_base/strings/string_builder.h"

namespace webrtc {

using rtc::SafeClamp;
using rtc::SafeGt;
using rtc::SafeEq;
using rtc::SafeLt;
using rtc::CheckedDivExact;
using rtc::dchecked_cast;
using rtc::StringBuilder;
using rtc::SimpleStringBuilder;

template <typename T>
size_t SamplesPerChannel(const MonoView<T>& view) { return view.size(); }

template <typename T>
rtc::ArrayView<T> MakeArrayView(T* data, size_t size) {
  return rtc::ArrayView<T>(data, size);
}

#ifndef RTC_DCHECK_NOTREACHED
#define RTC_DCHECK_NOTREACHED() RTC_DCHECK(false)
#endif

}  // namespace webrtc

#endif  // AUDIO_PROCESSING_AGC2_COMPAT_H_
