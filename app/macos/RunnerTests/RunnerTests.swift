import Cocoa
import ApplicationServices
import FlutterMacOS
import XCTest
@testable import LumaLex

final class RunnerTests: XCTestCase {
  func testContextIncludesSelectionAndStaysBounded() {
    let text = String(repeating: "before ", count: 100) + "forest" + String(repeating: " after", count: 100)
    let selected = (text as NSString).range(of: "forest")
    let context = DesktopSelection.boundedContext(text, selection: CFRange(location: selected.location, length: selected.length))
    XCTAssertTrue(context.contains("forest"))
    XCTAssertLessThanOrEqual(context.count, 500)
    XCTAssertEqual(DesktopSelection.boundedContext(text, selection: CFRange(location: -1, length: 6)), "")
    XCTAssertEqual(DesktopSelection.boundedContext(text, selection: CFRange(location: text.utf16.count + 1, length: 6)), "")
  }

  func testContextHandlesUnicodeAtDocumentEdges() {
    let text = "🌲 forest 你好" as NSString
    XCTAssertEqual(DesktopSelection.boundedContext(text as String, selection: CFRange(location: 3, length: 6)), text as String)
    XCTAssertEqual(DesktopSelection.boundedContext(text as String, selection: CFRange(location: text.length, length: 1)), "")
  }

  func testPopupRejectsRemoteFileAndCredentialOrigins() {
    XCTAssertTrue(LookupPanel.isLocalDictionaryURL(URL(string: "http://127.0.0.1:43210/dictionary/session/article")!))
    for raw in ["https://example.com/dictionary/session/article", "http://127.0.0.1/dictionary/session/article",
                "http://127.0.0.1:43210/settings", "file:///tmp/article.html",
                "http://key@127.0.0.1:43210/dictionary/session/article"] {
      XCTAssertFalse(LookupPanel.isLocalDictionaryURL(URL(string: raw)!), raw)
    }
  }

  func testKeychainRoundTripDoesNotTouchUserCredential() throws {
    let account = "native-test-" + UUID().uuidString
    defer { try? DesktopKeychain.delete(account: account) }
    XCTAssertEqual(try DesktopKeychain.load(account: account), "")
    try DesktopKeychain.save("local-test-key", account: account)
    XCTAssertEqual(try DesktopKeychain.load(account: account), "local-test-key")
    try DesktopKeychain.save("updated-local-test-key", account: account)
    XCTAssertEqual(try DesktopKeychain.load(account: account), "updated-local-test-key")
    try DesktopKeychain.delete(account: account)
    XCTAssertEqual(try DesktopKeychain.load(account: account), "")
  }
  func testPopupBridgeDeliversActionsAndClearsPendingAIOnClose() {
    let selected = expectation(description: "dictionary selected")
    let analyzed = expectation(description: "AI requested")
    var closeCount = 0
    let panel = LookupPanel { event, args in
      if event == "selectDictionary", args?["index"] as? Int == 2 { selected.fulfill() }
      if event == "analyzeAi" { analyzed.fulfill() }
      if event == "screenLookupClosed" { closeCount += 1 }
    }
    panel.showStatus(title: "forest", message: "Original local test text", anchor: NSEvent.mouseLocation)
    defer { panel.hide() }
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !panel.webView.isLoading }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
    panel.webView.evaluateJavaScript("chrome.webview.postMessage('dictionary:2'); chrome.webview.postMessage('analyzeAi');")
    wait(for: [selected, analyzed], timeout: 5)
    XCTAssertTrue(panel.waitingForAI)
    panel.hide()
    panel.hide()
    XCTAssertEqual(closeCount, 1)
    XCTAssertFalse(panel.waitingForAI)
  }

  func testCapturesSelectionFromOriginalTextEditFixtureWhenAvailable() throws {
    guard AXIsProcessTrusted() else { throw XCTSkip("Local accessibility permission is required for live capture QA.") }
    guard let editor = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
      throw XCTSkip("The original local TextEdit fixture is not open.")
    }
    let element = AXUIElementCreateApplication(editor.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.1)
    var rawWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
          let rawWindow = rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
      throw XCTSkip("The test fixture window is not available.")
    }
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(rawWindow as! AXUIElement, kAXTitleAttribute as CFString, &title)
    guard title as? String == "lumalex-selected-text-test.txt" else {
      throw XCTSkip("Only the agent-created, non-private test paragraph may be inspected.")
    }
    let selection = DesktopSelection.capture(pid: editor.processIdentifier)
    XCTAssertFalse(selection.protected)
    XCTAssertEqual(selection.text, "forest")
    XCTAssertTrue(selection.context.contains("We walked through the forest"))
    XCTAssertLessThanOrEqual(selection.context.count, 500)
  }

}
