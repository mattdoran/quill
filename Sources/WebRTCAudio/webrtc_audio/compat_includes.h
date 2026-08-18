#ifndef WEBRTC_COMPAT_INCLUDES_H_
#define WEBRTC_COMPAT_INCLUDES_H_

#ifdef _MSC_VER
#define _USE_MATH_DEFINES
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _HAS_DEPRECATED_RESULT_OF 1
#define _SILENCE_CXX20_IS_POD_DEPRECATION_WARNING
#endif

#include <stddef.h>

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <memory>
#include <vector>
#include <algorithm>
#include <functional>
#endif

#endif
