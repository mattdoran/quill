// Minimal shim for api/field_trials_view.h
// No-op implementation - all field trials disabled.
#ifndef API_FIELD_TRIALS_VIEW_H_
#define API_FIELD_TRIALS_VIEW_H_

#include <string>

namespace webrtc {

class FieldTrialsView {
 public:
  virtual ~FieldTrialsView() = default;
  virtual std::string Lookup(const std::string& key) const { return ""; }
  bool IsEnabled(const std::string& key) const { return false; }
  bool IsDisabled(const std::string& key) const { return false; }
};

}  // namespace webrtc

#endif  // API_FIELD_TRIALS_VIEW_H_
