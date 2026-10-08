#include <cassert>
#include <string>

#include "../runner/screen_lookup_hotkey.h"

int main() {
  ScreenLookupHotkey hotkey{};
  assert(ParseScreenLookupHotkey("ctrlAltL", &hotkey));
  assert(hotkey.modifiers == 3 && hotkey.key == 'L');
  assert(ParseScreenLookupHotkey("ctrlShiftL", &hotkey));
  assert(hotkey.modifiers == 6 && hotkey.key == 'L');
  assert(ParseScreenLookupHotkey("altQ", &hotkey));
  assert(hotkey.modifiers == 1 && hotkey.key == 'Q');
  for (unsigned int modifiers = 0; modifiers <= 9; ++modifiers) {
    for (unsigned int key = 0; key <= 255; ++key) {
      const bool expected = modifiers > 0 && modifiers < 8 &&
          (modifiers & 3) != 0 &&
          ((key >= 48 && key <= 57) || (key >= 65 && key <= 90) ||
           (key >= 112 && key <= 122)) &&
          !(modifiers == 2 && (key == 'A' || key == 'C' || key == 'V' ||
                              key == 'X' || key == 'Y' || key == 'Z')) &&
          !(modifiers == 1 && key == 0x73);
      const auto value = "custom:" + std::to_string(modifiers) + ":" + std::to_string(key);
      assert(ParseScreenLookupHotkey(value, &hotkey) == expected);
      if (expected) assert(hotkey.modifiers == modifiers && hotkey.key == key);
    }
  }
  for (const auto* value : {"custom:3:75oops", "custom:3:-75", "custom:3:+75",
                           "custom:03:75", "custom:3:123", "unknown"}) {
    assert(!ParseScreenLookupHotkey(value, &hotkey));
  }
  assert(!ParseScreenLookupHotkey("altQ", nullptr));
  return 0;
}
