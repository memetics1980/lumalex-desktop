#ifndef RUNNER_SCREEN_LOOKUP_HOTKEY_H_
#define RUNNER_SCREEN_LOOKUP_HOTKEY_H_

#include <charconv>
#include <string>
#include <system_error>

struct ScreenLookupHotkey {
  unsigned int modifiers;
  unsigned int key;
};

// Kept identical to the Dart storage format and allowed-key validation.
inline bool ParseScreenLookupHotkey(const std::string& value,
                                   ScreenLookupHotkey* result) {
  if (result == nullptr) return false;
  if (value == "ctrlAltL") { *result = {3, 'L'}; return true; }
  if (value == "ctrlShiftL") { *result = {6, 'L'}; return true; }
  if (value == "altQ") { *result = {1, 'Q'}; return true; }
  if (value.size() < 11 || value.size() > 12 ||
      value.compare(0, 7, "custom:") != 0 || value[8] != ':' ||
      value[7] < '1' || value[7] > '7') return false;
  const auto modifiers = static_cast<unsigned int>(value[7] - '0');
  if ((modifiers & 3) == 0) return false;
  unsigned int key = 0;
  const auto parsed = std::from_chars(value.data() + 9,
                                    value.data() + value.size(), key);
  if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size()) {
    return false;
  }
  if (!((key >= 0x30 && key <= 0x39) ||
        (key >= 0x41 && key <= 0x5a) ||
        (key >= 0x70 && key <= 0x7a))) return false;
  // Ctrl+C is also used by clipboard capture; never intercept it globally.
  if (modifiers == 2 && (key == 'A' || key == 'C' || key == 'V' ||
                         key == 'X' || key == 'Y' || key == 'Z')) return false;
  if (modifiers == 1 && key == 0x73) return false;  // Alt+F4 closes windows.
  *result = {modifiers, key};
  return true;
}

#endif  // RUNNER_SCREEN_LOOKUP_HOTKEY_H_
