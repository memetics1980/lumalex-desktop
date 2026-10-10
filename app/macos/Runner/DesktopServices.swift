import Cocoa
import Carbon
import ApplicationServices
import Security
import WebKit
import FlutterMacOS

/// Implements the shared desktop channel contract with macOS-owned services.
final class DesktopServices: NSObject, NSWindowDelegate, NSMenuItemValidation {
  weak var window: NSWindow?
  private let lookupChannel: FlutterMethodChannel
  private let lifecycleChannel: FlutterMethodChannel
  private var statusItem: NSStatusItem?
  private var hotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var shortcut = "ctrlAltL"
  private var shortcutRecording = false
  var hasRegisteredLookupShortcut: Bool { hotKey != nil }
  private var lookupEnabled = false
  private var hideOnClose = false
  private var terminating = false
  private var windowKeyObserver: NSObjectProtocol?
  private var capturing = false
  private var activationObserver: NSObjectProtocol?
  private var lastExternalApp: NSRunningApplication?
  private lazy var popup = LookupPanel { [weak self] event, arguments in
    self?.lookupChannel.invokeMethod(event, arguments: arguments)
    if event == "openInMain" { self?.restore() }
  }

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    lookupChannel = FlutterMethodChannel(name: "local_dictionary/macos_screen_lookup", binaryMessenger: messenger)
    lifecycleChannel = FlutterMethodChannel(name: "local_dictionary/macos_window_lifecycle", binaryMessenger: messenger)
    super.init()
    lookupChannel.setMethodCallHandler { [weak self] call, result in self?.handleLookup(call, result: result) }
    lifecycleChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "setCloseBehavior" else { result(FlutterMethodNotImplemented); return }
      self.setCloseBehavior(hideToMenuBar: (call.arguments as? [String: Any])?["behavior"] as? String == "hideToTray")
      result(nil)
    }
    windowKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
      object: window, queue: .main) { [weak self] _ in
        self?.lifecycleChannel.invokeMethod("restoredFromTray", arguments: nil)
      }
    lastExternalApp = NSWorkspace.shared.frontmostApplication
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
          self?.lastExternalApp = app
        }
      }
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      guard let userData = userData else { return OSStatus(eventNotHandledErr) }
      let services = Unmanaged<DesktopServices>.fromOpaque(userData).takeUnretainedValue()
      DispatchQueue.main.async { services.requestSelection() }
      return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
  }

  deinit {
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
    if let hotKeyHandler = hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    if let windowKeyObserver = windowKeyObserver { NotificationCenter.default.removeObserver(windowKeyObserver) }
    if let activationObserver = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }

  var keepsRunningInBackground: Bool { !terminating && (hideOnClose || lookupEnabled) }
  var hasMenuBarItem: Bool { statusItem?.isVisible == true && statusItem?.button != nil }

  func setCloseBehavior(hideToMenuBar: Bool) {
    hideOnClose = hideToMenuBar
    updateStatusItem()
  }

  func prepareForTermination() { terminating = true }

  /// Called by MainFlutterWindow itself, independent of Flutter's delegate.
  @discardableResult func handleMainWindowClose() -> Bool {
    guard !terminating else { return false }
    if hideOnClose || lookupEnabled {
      updateStatusItem()
      window?.orderOut(nil)
      lifecycleChannel.invokeMethod("hiddenToTray", arguments: nil)
    } else {
      terminating = true
      NSApp.terminate(nil)
    }
    return true
  }

  @objc func restore() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    lifecycleChannel.invokeMethod("restoredFromTray", arguments: nil)
  }

  @objc private func showSettings() {
    restore()
    lifecycleChannel.invokeMethod("showSettingsRequested", arguments: nil)
  }
  @objc private func lookupFromMenu() { requestSelection() }
  @objc private func quit() { prepareForTermination(); NSApp.terminate(nil) }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    item.action == #selector(lookupFromMenu) ? lookupEnabled : true
  }

  private func updateStatusItem() {
    if let menu = NSApp.mainMenu?.items.first?.submenu,
       menu.items.allSatisfy({ $0.identifier?.rawValue != "lumalex.settings" }) {
      let item = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
      item.identifier = NSUserInterfaceItemIdentifier("lumalex.settings")
      item.keyEquivalentModifierMask = .command
      item.target = self
      menu.insertItem(item, at: min(2, menu.items.count))
    }
    if let menu = NSApp.mainMenu?.items.first?.submenu,
       menu.items.allSatisfy({ $0.identifier?.rawValue != "lumalex.selectedtext" }) {
      let item = NSMenuItem(title: "查询选中文字", action: #selector(lookupFromMenu), keyEquivalent: "")
      item.identifier = NSUserInterfaceItemIdentifier("lumalex.selectedtext")
      item.target = self
      menu.insertItem(item, at: min(2, menu.items.count))
    }
    if !hideOnClose && !lookupEnabled {
      if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      statusItem = nil
      return
    }
    if statusItem == nil {
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "LumaLex")
      image?.isTemplate = true
      statusItem?.button?.image = image
      statusItem?.button?.title = image == nil ? "LL" : ""
      statusItem?.button?.toolTip = "LumaLex"
      statusItem?.button?.setAccessibilityLabel("LumaLex 菜单栏")
      statusItem?.isVisible = true
    }
    let menu = NSMenu()
    for (title, action) in [("打开 LumaLex", #selector(restore)), ("设置…", #selector(showSettings)),
                            ("查询选中文字", #selector(lookupFromMenu)), ("退出 LumaLex", #selector(quit))] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      if action == #selector(lookupFromMenu) { item.isEnabled = lookupEnabled }
      menu.addItem(item)
    }
    statusItem?.menu = menu
  }

  private func configure(enabled: Bool, shortcut newShortcut: String) throws {
    guard let combination = DesktopLookupShortcut.parse(newShortcut) else {
      throw DesktopServiceError.message("invalid_shortcut", "不支持此取词快捷键。")
    }
    if enabled && hotKeyHandler == nil {
      throw DesktopServiceError.message("hotkey_handler_unavailable", "无法初始化系统快捷键服务。")
    }
    if enabled && !shortcutRecording && (hotKey == nil || !lookupEnabled || newShortcut != shortcut) {
      var candidate: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x4C554D41), id: 1)
      let status = RegisterEventHotKey(combination.key, combination.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
      guard status == noErr, let candidate = candidate else {
        throw DesktopServiceError.message("hotkey_unavailable", "快捷键已被占用，请选择其他组合。")
      }
      if let old = hotKey { UnregisterEventHotKey(old) }
      hotKey = candidate
    } else if !enabled, let old = hotKey {
      UnregisterEventHotKey(old)
      hotKey = nil
    }
    shortcut = newShortcut
    lookupEnabled = enabled
    updateStatusItem()
  }

  private func handleLookup(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let anchor = NSPoint(x: (args["x"] as? NSNumber)?.doubleValue ?? NSEvent.mouseLocation.x,
                         y: (args["y"] as? NSNumber)?.doubleValue ?? NSEvent.mouseLocation.y)
    do {
      switch call.method {
      case "configure":
        try configure(enabled: args["enabled"] as? Bool ?? false, shortcut: args["shortcut"] as? String ?? "ctrlAltL")
        result(nil)
      case "setShortcutRecording":
        let recording = args["recording"] as? Bool ?? false
        if recording, !shortcutRecording {
          if let old = hotKey { UnregisterEventHotKey(old); hotKey = nil }
          shortcutRecording = true
        } else if !recording, shortcutRecording {
          shortcutRecording = false
          do { try configure(enabled: lookupEnabled, shortcut: shortcut) }
          catch { lookupEnabled = false; updateStatusItem(); throw error }
        }
        result(nil)
      case "hasAccessibilityPermission": result(DesktopAccessibilityPermission.isGranted())
      case "openAccessibilitySettings":
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
          NSWorkspace.shared.open(url)
        }
        result(nil)
      case "showCurrentApplication":
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        result(nil)
      case "showLoading":
        popup.query = args["query"] as? String ?? ""
        popup.showStatus(title: popup.query, message: "正在查询本地词典…", anchor: anchor)
        result(nil)
      case "showArticle":
        guard let raw = args["uri"] as? String, let url = URL(string: raw), LookupPanel.isLocalDictionaryURL(url) else {
          throw DesktopServiceError.message("invalid_origin", "词条地址必须来自本地词典服务。")
        }
        if let query = args["query"] as? String, !query.isEmpty, query.count <= 128 {
          popup.query = query
        }
        popup.showArticle(url, anchor: anchor)
        result(nil)
      case "showMessage":
        popup.showStatus(title: args["title"] as? String ?? "LumaLex", message: args["message"] as? String ?? "", anchor: anchor)
        result(nil)
      case "hide": popup.hide(); result(nil)
      case "updateAiResult":
        popup.updateAI(args["payload"] as? String ?? "", pending: args["pending"] as? Bool ?? false)
        result(nil)
      case "loadAiApiKey": result(try DesktopKeychain.load())
      case "saveAiApiKey": try DesktopKeychain.save(args["apiKey"] as? String ?? ""); result(nil)
      case "deleteAiApiKey": try DesktopKeychain.delete(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch DesktopServiceError.message(let code, let message) {
      result(FlutterError(code: code, message: message, details: nil))
    } catch { result(FlutterError(code: "native_failure", message: "系统操作失败。", details: nil)) }
  }

  private func unavailable(_ error: String, anchor: NSPoint) {
    NSLog("LumaLex selection unavailable: %@", error)
    lookupChannel.invokeMethod("lookupUnavailable", arguments: ["error": error, "x": Int(anchor.x), "y": Int(anchor.y)])
  }

  private func publish(_ text: String, context: String, anchor: NSPoint, copied: Bool) {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf16.count <= 128 else { unavailable("empty", anchor: anchor); return }
    NSLog("LumaLex selection ready: queryLength=%d, contextLength=%d, clipboard=%d", query.utf16.count, context.utf16.count, copied ? 1 : 0)
    lookupChannel.invokeMethod("lookupRequested", arguments: ["text": query, "context": context,
      "x": Int(anchor.x), "y": Int(anchor.y), "usedClipboardFallback": copied])
  }

  private func requestSelection() {
    guard lookupEnabled, !shortcutRecording, !capturing else { return }
    let anchor = NSEvent.mouseLocation
    NSLog("LumaLex selection request received")
    guard DesktopAccessibilityPermission.isGranted() else { unavailable("permission", anchor: anchor); return }
    guard !IsSecureEventInputEnabled() else { unavailable("protected", anchor: anchor); return }
    let frontmost = NSWorkspace.shared.frontmostApplication
    let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : frontmost
    guard let target = target, !target.isTerminated else { unavailable("empty", anchor: anchor); return }
    capturing = true
    let pid = target.processIdentifier
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let selection = DesktopSelection.capture(pid: pid)
      DispatchQueue.main.async {
        guard let self = self else { return }
        if selection.protected {
          self.capturing = false
          self.unavailable("protected", anchor: anchor)
        } else if !selection.text.isEmpty {
          self.capturing = false
          self.publish(selection.text, context: selection.context, anchor: anchor, copied: false)
        } else {
          self.copySelection(target: target, anchor: anchor)
        }
      }
    }
  }

  private func copySelection(target: NSRunningApplication, anchor: NSPoint) {
    // Password and secure-input checks precede any simulated copy. Never use a
    // pre-existing clipboard value as evidence of the user's current selection.
    guard !IsSecureEventInputEnabled(), !target.isTerminated else {
      capturing = false; unavailable("protected", anchor: anchor); return
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
      capturing = false; unavailable("empty", anchor: anchor); return
    }
    let before = NSPasteboard.general.changeCount
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    let deadline = Date().addingTimeInterval(0.8)
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }
      if NSPasteboard.general.changeCount != before {
        timer.invalidate(); self.capturing = false
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        self.publish(text, context: "", anchor: anchor, copied: true)
      } else if Date() >= deadline {
        timer.invalidate(); self.capturing = false; self.unavailable("empty", anchor: anchor)
      }
    }
  }
}

enum DesktopAccessibilityPermission {
  static func resolve(reportedTrusted: Bool, probeResult: AXError?) -> Bool {
    if reportedTrusted { return true }
    // A successful, permission-checked AX request is stronger evidence than
    // a cached false result. Never treat a timeout or API denial as a grant.
    return probeResult == .success
  }

  static func isGranted() -> Bool {
    let reported = AXIsProcessTrusted()
    if reported { return true }
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
      return false
    }
    let application = AXUIElementCreateApplication(finder.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.1)
    var ignored: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &ignored)
    return resolve(reportedTrusted: false, probeResult: result)
  }
}

enum DesktopServiceError: Error { case message(String, String) }

enum DesktopKeychain {
  private static func identity(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.memetics.lumalex") + ".contextual-ai", kSecAttrAccount as String: account] }
  static func load(account: String = "api-key") throws -> String {
    var query = identity(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
      throw DesktopServiceError.message("keychain_read_failed", "无法读取钥匙串中的 API Key。")
    }
    return key
  }
  static func save(_ key: String, account: String = "api-key") throws {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DesktopServiceError.message("empty_key", "API Key 不能为空。")
    }
    let data = Data(key.utf8)
    var status = SecItemUpdate(identity(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var query = identity(account); query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(query as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw DesktopServiceError.message("keychain_write_failed", "无法保存 API Key 到钥匙串。") }
  }
  static func delete(account: String = "api-key") throws {
    let status = SecItemDelete(identity(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DesktopServiceError.message("keychain_delete_failed", "无法从钥匙串删除 API Key。")
    }
  }
}

struct DesktopLookupShortcut {
  let key: UInt32
  let modifiers: UInt32
  static func parse(_ name: String) -> DesktopLookupShortcut? {
    let bits: Int, virtualKey: Int
    switch name {
    case "ctrlAltL": bits = 3; virtualKey = 0x4c
    case "ctrlShiftL": bits = 6; virtualKey = 0x4c
    case "altQ": bits = 1; virtualKey = 0x51
    default:
      let parts = name.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0] == "custom", let mask = Int(parts[1]),
            let code = Int(parts[2]) else { return nil }
      bits = mask; virtualKey = code
    }
    guard bits > 0, bits < 8, bits & 3 != 0,
          !(bits == 2 && [0x41, 0x43, 0x56, 0x58, 0x59, 0x5a].contains(virtualKey)),
          !(bits == 1 && virtualKey == 0x73) else { return nil }
    // Shared storage uses Windows virtual keys, never Carbon's hardware codes.
    let letters = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
                   45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    let digits = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    let functions = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103]
    let key: Int
    switch virtualKey {
    case 0x41...0x5a: key = letters[virtualKey - 0x41]
    case 0x30...0x39: key = digits[virtualKey - 0x30]
    case 0x70...0x7a: key = functions[virtualKey - 0x70]
    default: return nil
    }
    let modifiers = (bits & 2 != 0 ? cmdKey : 0) | (bits & 1 != 0 ? optionKey : 0) | (bits & 4 != 0 ? shiftKey : 0)
    return DesktopLookupShortcut(key: UInt32(key), modifiers: UInt32(modifiers))
  }
}

struct DesktopSelection {
  let text: String
  let context: String
  let protected: Bool
  private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    // AX messaging timeouts belong to individual elements. Apply the bound to
    // descendants too so a non-responsive reader cannot stall capture for 30s.
    AXUIElementSetMessagingTimeout(element, 0.08)
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
  }
  private static func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }
  private static func isProtected(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<6 {
      guard let node = current else { break }
      if value(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return true }
      current = self.element(value(node, kAXParentAttribute))
    }
    return false
  }
  static func boundedContext(_ source: String, selection: CFRange) -> String {
    let text = source as NSString
    guard selection.location >= 0, selection.length > 0,
          selection.location <= text.length, selection.length <= text.length - selection.location else { return "" }
    let start = max(0, selection.location - max(0, (500 - selection.length) / 2))
    let length = min(500, text.length - start)
    let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length))
    return String(text.substring(with: range).prefix(500))
  }
  private static func parameter(_ node: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(node, 0.08)
    var result: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(node, name as CFString, argument, &result) == .success ? result : nil
  }
  private static func startMarker(_ range: CFTypeRef, node: AXUIElement) -> CFTypeRef? {
    // AXStartTextMarkerForTextMarkerRange is not a Chromium parameterized
    // attribute. Extract the opaque marker through ApplicationServices instead.
    typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AXTextMarkerRangeCopyStartMarker") else {
      return parameter(node, "AXStartTextMarkerForTextMarkerRange", range)
    }
    let copy = unsafeBitCast(symbol, to: CopyMarker.self)
    return copy(range)?.takeRetainedValue()
  }

  private static func markerSelection(_ node: AXUIElement) -> (text: String, context: String)? {
    // WebKit and Chromium expose selections spanning DOM nodes as text markers
    // rather than ordinary CFRange attributes. Request the enclosing paragraph;
    // never upload an entire page or guess a context from another paragraph.
    guard let range = value(node, "AXSelectedTextMarkerRange"),
          let text = parameter(node, "AXStringForTextMarkerRange", range) as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let start = startMarker(range, node: node),
          let paragraph = parameter(node, "AXParagraphTextMarkerRangeForTextMarker", start),
          let source = parameter(node, "AXStringForTextMarkerRange", paragraph) as? String,
          source.contains(text) else { return (text, "") }
    if source.utf16.count <= 500 { return (text, source) }
    guard let paragraphStart = startMarker(paragraph, node: node),
          let selectionIndex = parameter(node, "AXIndexForTextMarker", start) as? NSNumber,
          let paragraphIndex = parameter(node, "AXIndexForTextMarker", paragraphStart) as? NSNumber else { return (text, "") }
    return (text, boundedContext(source, selection: CFRange(location: selectionIndex.intValue - paragraphIndex.intValue, length: text.utf16.count)))
  }
  private static func read(_ node: AXUIElement) -> DesktopSelection? {
    if isProtected(node) { return DesktopSelection(text: "", context: "", protected: true) }
    let marker = markerSelection(node)
    let text = preferredSelection(value(node, kAXSelectedTextAttribute) as? String, marker: marker?.text)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var selectedRange = CFRange(location: 0, length: 0)
    var context = marker?.context ?? ""
    if let raw = value(node, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
       AXValueGetValue(raw as! AXValue, .cfRange, &selectedRange), selectedRange.location >= 0,
       selectedRange.length > 0, selectedRange.length <= 128 {
      let count = (value(node, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
      var range = CFRange(location: max(0, selectedRange.location - (500 - selectedRange.length) / 2), length: 500)
      if let count = count { range.length = min(range.length, max(0, count - range.location)) }
      if let parameter = AXValueCreate(.cfRange, &range) {
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(node, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
           let nearby = result as? String { context = String(nearby.prefix(500)) }
      }
      if context.isEmpty, let source = value(node, kAXValueAttribute) as? String {
        context = boundedContext(source, selection: selectedRange)
      }
    }
    return DesktopSelection(text: text, context: context, protected: false)
  }
  static func preferredSelection(_ ordinary: String?, marker: String?) -> String {
    if let ordinary = ordinary, !ordinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ordinary }
    return marker ?? ""
  }

  // Depth-first exploration reaches page content before spending the budget on
  // every browser toolbar sibling. AXContents also exposes Safari's web area.
  static func findSelection<Node>(roots: [Node], budget: Int,
                                  children: (Node) -> [Node],
                                  read: (Node) -> DesktopSelection?,
                                  same: (Node, Node) -> Bool,
                                  withinDeadline: () -> Bool) -> DesktopSelection? {
    var stack = roots.reversed().map { ($0, 0) }
    var visited: [Node] = []
    var best: DesktopSelection?
    while let (node, depth) = stack.popLast(), visited.count < budget, withinDeadline() {
      if visited.contains(where: { same($0, node) }) { continue }
      visited.append(node)
      if let selection = read(node) {
        if selection.protected { return selection }
        if best == nil { best = selection }
        if !selection.context.isEmpty, best?.text == selection.text { return selection }
      }
      if depth < 20 { stack.append(contentsOf: children(node).prefix(80).reversed().map { ($0, depth + 1) }) }
    }
    return best
  }

  private static var preparedBrowsers = Set<pid_t>()

  static func capture(pid: pid_t) -> DesktopSelection {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    let browser = ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                   "com.brave.Browser", "org.chromium.Chromium", "org.mozilla.firefox"].contains(bundle)
    if browser, !preparedBrowsers.contains(pid) {
      let attribute = bundle == "org.mozilla.firefox" ? "AXManualAccessibility" : "AXEnhancedUserInterface"
      let result = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
      NSLog("LumaLex browser accessibility activation: result=%d", result.rawValue)
      if result == .success {
        preparedBrowsers.insert(pid)
        // Chromium delays enabling complete accessibility mode by two seconds.
        Thread.sleep(forTimeInterval: bundle == "org.mozilla.firefox" ? 0.15 : 2.1)
      }
    }
    var best: DesktopSelection?
    // Accessibility trees may be generated asynchronously on the first request.
    // Retry on this background queue before falling back to simulated copy.
    for attempt in 0..<3 {
      if attempt > 0 { Thread.sleep(forTimeInterval: 0.12) }
      let focused = element(value(app, kAXFocusedUIElementAttribute))
      var roots: [AXUIElement] = []
      if let focused = focused {
        roots.append(focused)
        if let selection = read(focused), selection.protected { return selection }
        var parent = element(value(focused, kAXParentAttribute))
        for _ in 0..<6 {
          guard let node = parent else { break }
          roots.append(node)
          parent = element(value(node, kAXParentAttribute))
        }
      }
      if let window = element(value(app, kAXFocusedWindowAttribute)) { roots.append(window) }
      let deadline = Date().addingTimeInterval(0.6)
      let found = findSelection(roots: roots, budget: 180, children: { node in
        let contents = value(node, "AXContents") as? [AXUIElement] ?? []
        let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        // Web areas first, followed by containers; omit menu/toolbar subtrees
        // when traversing the window. The focused node is always read above.
        return contents + children.filter {
          let role = value($0, kAXRoleAttribute) as? String ?? ""
          return role != "AXToolbar" && role != "AXMenuBar" && role != "AXMenu"
        }
      }, read: read, same: { CFEqual($0, $1) }, withinDeadline: { Date() < deadline })
      if let found = found {
        if found.protected || !found.context.isEmpty { return found }
        if best == nil { best = found }
      }
    }
    return best ?? DesktopSelection(text: "", context: "", protected: false)
  }
}

private final class FloatingLookupWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class LookupWebView: WKWebView {
  // A global-shortcut popup must handle the first click while the source
  // browser remains the active application.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
}

private final class WeakPopupMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: LookupPanel?
  init(_ target: LookupPanel) { self.target = target }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}

final class LookupPanel: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
  var query = ""
  private let emit: (String, [String: Any]?) -> Void
  private var panel: FloatingLookupWindow!
  private(set) var webView: WKWebView!
  private var currentURL: URL?
  private var pinned = false
  private(set) var waitingForAI = false
  private var lastOutside: Date?
  private var dismissTimer: Timer?
  private var dragOrigin: NSPoint?
  private var manuallyPositioned = false

  init(emit: @escaping (String, [String: Any]?) -> Void) {
    self.emit = emit
    super.init()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(WeakPopupMessageHandler(self), name: "lumalex")
    configuration.userContentController.addUserScript(WKUserScript(source: """
      window.chrome = window.chrome || {};
      window.chrome.webview = {postMessage: function(value) {
        window.webkit.messageHandlers.lumalex.postMessage(String(value));
      }};
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView = LookupWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 560), configuration: configuration)
    webView.navigationDelegate = self
    panel = FloatingLookupWindow(contentRect: webView.frame,
      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "LumaLex — 查词浮窗"
    panel.isExcludedFromWindowsMenu = false
    panel.contentView = webView
    panel.minSize = NSSize(width: 360, height: 280)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
  }

  static func isLocalDictionaryURL(_ url: URL) -> Bool {
    url.scheme == "http" && url.host == "127.0.0.1" && (url.port ?? 0) > 0 &&
      url.user == nil && url.password == nil && url.path.hasPrefix("/dictionary/")
  }
  private func owns(_ url: URL) -> Bool {
    guard let current = currentURL else { return false }
    return Self.isLocalDictionaryURL(url) && url.port == current.port &&
      url.path.hasPrefix(current.deletingLastPathComponent().path + "/")
  }
  private func position(_ anchor: NSPoint) {
    if manuallyPositioned && panel.isVisible { return }
    let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
    guard let bounds = screen?.visibleFrame else { return }
    let width = min(500, bounds.width), height = min(560, bounds.height)
    panel.setFrame(NSRect(x: max(bounds.minX, min(anchor.x + 12, bounds.maxX - width)),
      y: max(bounds.minY, min(anchor.y - height - 12, bounds.maxY - height)), width: width, height: height), display: true)
  }
  private func show(_ anchor: NSPoint) {
    position(anchor)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(webView)
    lastOutside = nil
    if dismissTimer == nil {
      dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkDismissal() }
    }
  }
  private func checkDismissal() {
    guard panel.isVisible else { return }
    if pinned || waitingForAI || dragOrigin != nil || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
      lastOutside = nil; return
    }
    if lastOutside == nil { lastOutside = Date() }
    if Date().timeIntervalSince(lastOutside!) >= 5 { hide() }
  }
  private static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  func showStatus(title: String, message: String, anchor: NSPoint) {
    pinned = false; waitingForAI = false; manuallyPositioned = false; dragOrigin = nil; currentURL = nil
    webView.loadHTMLString("""
      <!doctype html><meta charset="utf-8"><style>body{font:16px -apple-system;padding:24px;color:#173638}button{float:right}h2{color:#087e87}</style>
      <button onclick="chrome.webview.postMessage('close')">×</button>
      <h2>\(Self.escaped(title))</h2><p>\(Self.escaped(message))</p>
      """, baseURL: nil)
    show(anchor)
  }
  func showArticle(_ url: URL, anchor: NSPoint) {
    currentURL = url
    webView.load(URLRequest(url: url))
    show(anchor)
  }
  func updateAI(_ payload: String, pending: Bool) {
    guard Data(base64Encoded: payload) != nil else { return }
    waitingForAI = pending
    lastOutside = nil
    // JSON encoding handles every quote and backslash without treating a
    // payload as executable JavaScript.
    if let data = try? JSONSerialization.data(withJSONObject: [payload]),
       let array = String(data: data, encoding: .utf8) {
      webView.evaluateJavaScript("window.lumalexApplyAiPayload && window.lumalexApplyAiPayload(\(array)[0]);", completionHandler: nil)
    }
  }
  func hide() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    dismissTimer?.invalidate(); dismissTimer = nil
    waitingForAI = false; pinned = false; dragOrigin = nil; manuallyPositioned = false
    emit("screenLookupClosed", nil)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let action = message.body as? String,
          message.frameInfo.request.url.map({ owns($0) || ($0.scheme == "about" && currentURL == nil) }) ?? (currentURL == nil) else { return }
    switch action {
    case "close": hide()
    case "openMain":
      let text = query; hide(); emit("openInMain", ["text": text])
    case "pin": pinned.toggle(); lastOutside = nil; emit("pinChanged", ["pinned": pinned])
    case "toggleFavorite": emit("toggleFavorite", nil)
    case "viewRelatedHeadword": emit("viewRelatedHeadword", nil)
    case "viewAiLemma": emit("viewAiLemma", nil)
    case "analyzeAi": waitingForAI = true; lastOutside = nil; emit("analyzeAi", nil)
    case "interact", "pointer:inside", "pointer:outside": lastOutside = nil
    case "drag:start": dragOrigin = panel.frame.origin
    case "drag:end:mouse", "drag:end:touch": dragOrigin = nil; lastOutside = nil
    default:
      if action.hasPrefix("dictionary:"), let index = Int(action.dropFirst(11)), index >= 0 {
        emit("selectDictionary", ["index": index])
      } else if action.hasPrefix("lookupForm:"), let index = Int(action.dropFirst(11)), index >= -1, index <= 7 {
        emit("selectLookupForm", ["index": index])
      } else if action.hasPrefix("scope:"), let code = Int(action.dropFirst(6)), code >= -2 {
        emit("selectDictionaryScope", ["scopeCode": code])
      } else if action.hasPrefix("playSound:") { emit("playSound", ["value": String(action.dropFirst(10))])
      } else if action.hasPrefix("speak:") { emit("speak", ["value": String(action.dropFirst(6))])
      } else if action.hasPrefix("drag:move:"), let origin = dragOrigin {
        let offsets = action.dropFirst(10).split(separator: ":")
        if offsets.count == 2, let x = Double(offsets[0]), let y = Double(offsets[1]), x.isFinite, y.isFinite {
          panel.setFrameOrigin(NSPoint(x: origin.x + x, y: origin.y - y)); manuallyPositioned = true
        }
      }
    }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
    if url.scheme == "about" && currentURL == nil || owns(url) { decisionHandler(.allow); return }
    if url.scheme?.lowercased() == "entry", let word = url.absoluteString.dropFirst(8).removingPercentEncoding {
      query = word
      emit("lookupRequested", ["text": word, "context": "", "x": Int(panel.frame.minX), "y": Int(panel.frame.maxY), "usedClipboardFallback": true])
    }
    decisionHandler(.cancel)
  }
}
