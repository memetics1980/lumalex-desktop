#include "screen_lookup_service.h"

#include <UIAutomation.h>
#include <ole2.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cwctype>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr int kMaximumLookupTextLength = 128;
constexpr int kMaximumLookupContextLength = 500;
constexpr int kLookupContextRadius = 240;
constexpr int kMaximumSelectionRanges = 64;

enum class AutomationReadResult { kUnavailable, kProtected, kFound };

std::wstring NormalizeLookupText(const std::wstring& value) {
  std::wstring output;
  output.reserve(value.size());
  bool previous_was_space = false;
  for (const wchar_t character : value) {
    const bool is_space = iswspace(character) != 0;
    if (is_space) {
      if (!output.empty() && !previous_was_space) {
        output.push_back(L' ');
      }
    } else {
      output.push_back(character);
    }
    previous_was_space = is_space;
  }
  while (!output.empty() && iswspace(output.back()) != 0) {
    output.pop_back();
  }
  return output;
}

std::wstring Lowercase(const std::wstring& value) {
  std::wstring output = value;
  std::transform(output.begin(), output.end(), output.begin(), towlower);
  return output;
}

bool ShouldPreferClipboardForWindow(HWND window) {
  if (window == nullptr) {
    return false;
  }
  const int title_length = GetWindowTextLengthW(window);
  std::wstring title(static_cast<size_t>(std::max(0, title_length)) + 1,
                     L'\0');
  if (title_length > 0) {
    GetWindowTextW(window, title.data(), title_length + 1);
    title.resize(wcslen(title.c_str()));
    if (Lowercase(title).find(L".pdf") != std::wstring::npos) {
      return true;
    }
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0) {
    return false;
  }
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               process_id);
  if (process == nullptr) {
    return false;
  }
  std::wstring process_path(32768, L'\0');
  DWORD process_path_length = static_cast<DWORD>(process_path.size());
  const bool read_path =
      QueryFullProcessImageNameW(process, 0, process_path.data(),
                                 &process_path_length) != FALSE;
  CloseHandle(process);
  if (!read_path) {
    return false;
  }
  process_path.resize(process_path_length);
  const std::wstring lower_path = Lowercase(process_path);
  return lower_path.find(L"foxitpdf") != std::wstring::npos ||
         lower_path.find(L"acrord") != std::wstring::npos ||
         lower_path.find(L"acrobat") != std::wstring::npos ||
         lower_path.find(L"sumatrapdf") != std::wstring::npos;
}

std::wstring ReadTextRange(IUIAutomationTextRange* range, int maximum_length) {
  if (range == nullptr || maximum_length <= 0) {
    return std::wstring();
  }
  BSTR raw_text = nullptr;
  if (FAILED(range->GetText(maximum_length, &raw_text)) ||
      raw_text == nullptr) {
    return std::wstring();
  }
  std::wstring result(raw_text, SysStringLen(raw_text));
  SysFreeString(raw_text);
  return result;
}

std::wstring RecoverDroppedLeadingCharacter(
    IUIAutomationTextRange* range,
    const std::wstring& raw_text) {
  const std::wstring normalized = NormalizeLookupText(raw_text);
  if (range == nullptr || normalized.empty()) {
    return raw_text;
  }

  // Chromium-based document providers can expose a selection whose text range
  // begins one character after the visible highlight. Extending a clone by one
  // character recovers that letter. For a correct range preceded by whitespace,
  // normalization produces the original value and this remains a no-op.
  ComPtr<IUIAutomationTextRange> expanded;
  if (FAILED(range->Clone(&expanded)) || expanded == nullptr) {
    return raw_text;
  }
  int moved = 0;
  if (FAILED(expanded->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,
                                          TextUnit_Character, -1, &moved)) ||
      moved != -1) {
    return raw_text;
  }
  const std::wstring expanded_raw =
      ReadTextRange(expanded.Get(), kMaximumLookupTextLength + 2);
  const std::wstring expanded_text = NormalizeLookupText(expanded_raw);
  if (expanded_text.length() != normalized.length() + 1 ||
      iswalnum(expanded_text.front()) == 0 ||
      expanded_text.compare(1, normalized.length(), normalized) != 0) {
    return raw_text;
  }
  return expanded_raw;
}

std::wstring ReadContextAroundRange(IUIAutomationTextRange* range,
                                    const std::wstring& selection_text) {
  if (range == nullptr) {
    return std::wstring();
  }
  ComPtr<IUIAutomationTextRange> expanded;
  if (FAILED(range->Clone(&expanded)) || expanded == nullptr) {
    return std::wstring();
  }
  int ignored = 0;
  expanded->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,
                               TextUnit_Character, -kLookupContextRadius,
                               &ignored);
  expanded->MoveEndpointByUnit(TextPatternRangeEndpoint_End,
                               TextUnit_Character, kLookupContextRadius,
                               &ignored);
  std::wstring context = NormalizeLookupText(
      ReadTextRange(expanded.Get(), kMaximumLookupContextLength + 1));
  if (context.length() <= kMaximumLookupContextLength) {
    return context;
  }
  const std::wstring normalized_selection =
      NormalizeLookupText(selection_text);
  const size_t selected_at = context.find(normalized_selection);
  if (selected_at == std::wstring::npos) {
    context.resize(kMaximumLookupContextLength);
    return context;
  }
  const size_t remaining =
      kMaximumLookupContextLength - normalized_selection.length();
  const size_t start =
      selected_at > remaining / 2 ? selected_at - remaining / 2 : 0;
  return context.substr(start, kMaximumLookupContextLength);
}

AutomationReadResult ReadSelectionFromElement(
    IUIAutomationElement* element,
    std::wstring* text,
    std::wstring* context) {
  if (element == nullptr || text == nullptr || context == nullptr) {
    return AutomationReadResult::kUnavailable;
  }
  BOOL is_password = FALSE;
  if (SUCCEEDED(element->get_CurrentIsPassword(&is_password)) && is_password) {
    return AutomationReadResult::kProtected;
  }

  ComPtr<IUIAutomationTextPattern> pattern;
  if (FAILED(element->GetCurrentPatternAs(
          UIA_TextPatternId, IID_PPV_ARGS(&pattern))) ||
      pattern == nullptr) {
    return AutomationReadResult::kUnavailable;
  }
  ComPtr<IUIAutomationTextRangeArray> ranges;
  if (FAILED(pattern->GetSelection(&ranges)) || ranges == nullptr) {
    return AutomationReadResult::kUnavailable;
  }
  int range_count = 0;
  if (FAILED(ranges->get_Length(&range_count)) || range_count <= 0 ||
      range_count > kMaximumSelectionRanges) {
    return AutomationReadResult::kUnavailable;
  }

  std::wstring combined;
  std::wstring selected_context;
  for (int index = 0; index < range_count; ++index) {
    ComPtr<IUIAutomationTextRange> range;
    if (FAILED(ranges->GetElement(index, &range)) || range == nullptr) {
      continue;
    }
    std::wstring raw_text =
        ReadTextRange(range.Get(), kMaximumLookupTextLength + 1);
    if (!raw_text.empty()) {
      if (range_count == 1) {
        raw_text = RecoverDroppedLeadingCharacter(range.Get(), raw_text);
        selected_context = ReadContextAroundRange(range.Get(), raw_text);
      }
      if (!combined.empty()) {
        combined.push_back(L' ');
      }
      combined.append(raw_text);
    }
  }
  combined = NormalizeLookupText(combined);
  if (combined.empty()) {
    return AutomationReadResult::kUnavailable;
  }
  *text = std::move(combined);
  *context = std::move(selected_context);
  return AutomationReadResult::kFound;
}

AutomationReadResult ReadSelectionWithAncestors(
    IUIAutomation* automation,
    IUIAutomationElement* initial_element,
    std::wstring* text,
    std::wstring* context) {
  if (automation == nullptr || initial_element == nullptr || text == nullptr ||
      context == nullptr) {
    return AutomationReadResult::kUnavailable;
  }
  ComPtr<IUIAutomationTreeWalker> walker;
  if (FAILED(automation->get_RawViewWalker(&walker)) || walker == nullptr) {
    return ReadSelectionFromElement(initial_element, text, context);
  }

  ComPtr<IUIAutomationElement> element = initial_element;
  for (int depth = 0; depth < 8 && element != nullptr; ++depth) {
    const AutomationReadResult result =
        ReadSelectionFromElement(element.Get(), text, context);
    if (result != AutomationReadResult::kUnavailable) {
      return result;
    }
    ComPtr<IUIAutomationElement> parent;
    if (FAILED(walker->GetParentElement(element.Get(), &parent))) {
      break;
    }
    element = std::move(parent);
  }
  return AutomationReadResult::kUnavailable;
}

AutomationReadResult ReadUiAutomationSelection(const POINT& anchor,
                                                std::wstring* text,
                                                std::wstring* context) {
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation))) ||
      automation == nullptr) {
    return AutomationReadResult::kUnavailable;
  }

  ComPtr<IUIAutomationElement> focused;
  AutomationReadResult focused_result = AutomationReadResult::kUnavailable;
  if (SUCCEEDED(automation->GetFocusedElement(&focused)) &&
      focused != nullptr) {
    focused_result = ReadSelectionWithAncestors(automation.Get(), focused.Get(),
                                                text, context);
    if (focused_result == AutomationReadResult::kProtected ||
        (focused_result == AutomationReadResult::kFound && !context->empty())) {
      return focused_result;
    }
  }

  ComPtr<IUIAutomationElement> pointed;
  if (SUCCEEDED(automation->ElementFromPoint(anchor, &pointed)) &&
      pointed != nullptr) {
    std::wstring pointed_text;
    std::wstring pointed_context;
    const AutomationReadResult pointed_result = ReadSelectionWithAncestors(
        automation.Get(), pointed.Get(), &pointed_text, &pointed_context);
    if (pointed_result == AutomationReadResult::kProtected) {
      return pointed_result;
    }
    if (pointed_result == AutomationReadResult::kFound &&
        (focused_result != AutomationReadResult::kFound ||
         pointed_text == *text)) {
      *text = std::move(pointed_text);
      *context = std::move(pointed_context);
      return pointed_result;
    }
  }
  return focused_result;
}

// Third-party accessibility providers execute across a COM boundary and some
// PDF implementations have been observed to raise a structured exception
// instead of returning a failing HRESULT. Keep one broken provider from
// terminating the whole dictionary process; the caller can still use the
// clipboard path.
AutomationReadResult ReadUiAutomationSelectionSafely(
    const POINT& anchor,
    std::wstring* text,
    std::wstring* context) {
#if defined(_MSC_VER)
  __try {
    return ReadUiAutomationSelection(anchor, text, context);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    if (text != nullptr) {
      text->clear();
    }
    if (context != nullptr) {
      context->clear();
    }
    return AutomationReadResult::kUnavailable;
  }
#else
  return ReadUiAutomationSelection(anchor, text, context);
#endif
}

bool WaitForLookupModifiersToBeReleased() {
  int stable_release_polls = 0;
  for (int attempt = 0; attempt < 80; ++attempt) {
    const bool control_down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
    const bool alt_down = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
    const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
    if (!control_down && !alt_down && !shift_down) {
      ++stable_release_polls;
      if (stable_release_polls >= 3) {
        // Foxit updates its command routing shortly after the global shortcut
        // modifiers are released. Give it one frame before injecting Ctrl+C.
        Sleep(40);
        return true;
      }
    } else {
      stable_release_polls = 0;
    }
    Sleep(10);
  }
  return false;
}

bool SendCopyShortcut() {
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'C';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'C';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  constexpr UINT input_count = static_cast<UINT>(std::size(inputs));
  return SendInput(input_count, inputs, sizeof(INPUT)) == input_count;
}

std::wstring ReadClipboardText(HWND owner) {
  for (int attempt = 0; attempt < 60; ++attempt) {
    if (OpenClipboard(owner)) {
      std::wstring result;
      HANDLE unicode_data = GetClipboardData(CF_UNICODETEXT);
      if (unicode_data != nullptr) {
        const auto* value =
            static_cast<const wchar_t*>(GlobalLock(unicode_data));
        if (value != nullptr) {
          result.assign(value);
          GlobalUnlock(unicode_data);
        }
      } else {
        HANDLE ansi_data = GetClipboardData(CF_TEXT);
        const auto* value = ansi_data == nullptr
                                ? nullptr
                                : static_cast<const char*>(GlobalLock(ansi_data));
        if (value != nullptr) {
          const int required = MultiByteToWideChar(
              CP_ACP, 0, value, -1, nullptr, 0);
          if (required > 1) {
            result.resize(static_cast<size_t>(required));
            MultiByteToWideChar(CP_ACP, 0, value, -1, result.data(), required);
            result.resize(static_cast<size_t>(required - 1));
          }
          GlobalUnlock(ansi_data);
        }
      }
      CloseClipboard();
      return NormalizeLookupText(result);
    }
    Sleep(10);
  }
  return std::wstring();
}

std::wstring ReadSelectionThroughClipboard(HWND owner) {
  const DWORD initial_sequence = GetClipboardSequenceNumber();
  if (!WaitForLookupModifiersToBeReleased() || !SendCopyShortcut()) {
    return std::wstring();
  }

  auto wait_for_change = [](DWORD sequence, int attempts) {
    for (int attempt = 0; attempt < attempts; ++attempt) {
      if (GetClipboardSequenceNumber() != sequence) {
        return true;
      }
      Sleep(10);
    }
    return false;
  };

  bool changed = wait_for_change(initial_sequence, 120);
  std::wstring result = changed ? ReadClipboardText(owner) : std::wstring();
  if (result.empty()) {
    // Foxit can ignore the first synthetic copy while it dismisses its own
    // selection toolbar. A single delayed retry is bounded and leaves normal
    // browser lookup on the UI Automation path.
    const DWORD retry_sequence = GetClipboardSequenceNumber();
    Sleep(80);
    if (SendCopyShortcut() && wait_for_change(retry_sequence, 120)) {
      changed = true;
      result = ReadClipboardText(owner);
    }
  }
  // Compatibility mode intentionally keeps the selected text in the
  // clipboard. Restoring arbitrary third-party clipboard objects proved
  // unreliable in PDF editors, while leaving the copied word matches the
  // user's explicit fallback workflow and is consistent across applications.
  return result;
}

}  // namespace

ScreenLookupService::ScreenLookupService() = default;

ScreenLookupService::~ScreenLookupService() {
  if (worker_.joinable()) {
    worker_.join();
  }
}

bool ScreenLookupService::RequestSelection(HWND owner,
                                           UINT completion_message) {
  if (owner == nullptr || completion_message == 0 ||
      in_progress_.exchange(true)) {
    return false;
  }
  if (worker_.joinable()) {
    worker_.join();
  }
  POINT anchor{};
  GetCursorPos(&anchor);
  const HWND target_window = GetForegroundWindow();
  const bool prefer_clipboard = ShouldPreferClipboardForWindow(target_window);
  worker_ = std::thread(
      [this, owner, completion_message, anchor, prefer_clipboard]() {
    auto result = std::make_unique<ScreenLookupResult>();
    result->anchor = anchor;
    const HRESULT ole_result = OleInitialize(nullptr);
    const bool should_uninitialize = SUCCEEDED(ole_result);

    try {
      AutomationReadResult automation_result =
          AutomationReadResult::kUnavailable;
      if (prefer_clipboard) {
        // PDF accessibility trees often expose glyphs in drawing order rather
        // than reading order. Prefer the application's own Copy result and do
        // not use that unreliable text layer as AI context.
        result->text = ReadSelectionThroughClipboard(owner);
        result->used_clipboard_fallback = !result->text.empty();
      }
      if (result->text.empty()) {
        automation_result = ReadUiAutomationSelectionSafely(
            anchor, &result->text, &result->context);
        // The first accessibility read after a hotkey can precede the
        // provider's selection/context update. In particular, a browser may
        // expose the selected word before its surrounding TextRange is ready.
        // Retry only this read, before resorting to Ctrl+C, so the first
        // lookup can offer contextual AI just like subsequent lookups.
        for (int retry = 0;
             !prefer_clipboard &&
             automation_result != AutomationReadResult::kProtected &&
             result->context.empty() && retry < 2;
             ++retry) {
          Sleep(retry == 0 ? 80 : 160);
          std::wstring retry_text;
          std::wstring retry_context;
          const AutomationReadResult retry_result =
              ReadUiAutomationSelectionSafely(anchor, &retry_text,
                                              &retry_context);
          if (retry_result == AutomationReadResult::kProtected) {
            if (result->text.empty()) {
              automation_result = retry_result;
            }
            break;
          }
          if (retry_result != AutomationReadResult::kFound ||
              retry_text.empty()) {
            continue;
          }
          if (!result->text.empty() && retry_text != result->text) {
            continue;
          }
          result->text = std::move(retry_text);
          result->context = std::move(retry_context);
          automation_result = retry_result;
        }
      }
      if (result->text.empty()) {
        if (automation_result == AutomationReadResult::kProtected) {
          result->error = "protected";
        } else if (!prefer_clipboard) {
          result->text = ReadSelectionThroughClipboard(owner);
          result->used_clipboard_fallback = !result->text.empty();
        }
        if (result->text.empty() && result->error.empty()) {
          result->error = "no_selection";
        }
      }

      if (result->text.length() > kMaximumLookupTextLength) {
        result->text.clear();
        result->context.clear();
        result->error = "selection_too_long";
      }
    } catch (...) {
      // No malformed accessibility tree or clipboard provider should be able
      // to escape the worker thread and call std::terminate on LumaLex.
      result->text.clear();
      result->context.clear();
      result->error = "read_failed";
    }
    if (should_uninitialize) {
      OleUninitialize();
    }
    in_progress_ = false;
    if (IsWindow(owner)) {
      PostMessage(owner, completion_message, 0,
                  reinterpret_cast<LPARAM>(result.release()));
    }
  });
  return true;
}
