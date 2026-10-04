import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    DictionaryFileAccessChannel.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

private final class DictionaryFileAccessChannel {
  private static let channelName = "local_dictionary/file_access"
  private static let bookmarks = SecurityScopedBookmarks()

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid-arguments", message: "A file path is required.", details: nil))
        return
      }

      do {
        switch call.method {
        case "saveReadBookmark":
          result(try bookmarks.save(path: path))
        case "restoreReadBookmark":
          result(try bookmarks.restore(path: path))
        case "revokeReadBookmark":
          bookmarks.revoke(path: path)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(
          code: "file-access",
          message: "Could not restore access to the selected dictionary file.",
          details: error.localizedDescription
        ))
      }
    }
  }
}

private final class SecurityScopedBookmarks {
  private let defaults = UserDefaults.standard
  private let keyPrefix = "local_dictionary.read_bookmark."
  private var accessedURLs: [String: URL] = [:]

  deinit {
    for url in accessedURLs.values {
      url.stopAccessingSecurityScopedResource()
    }
  }

  func save(path: String) throws -> Bool {
    let url = normalizedURL(for: path)
    let bookmark = try url.bookmarkData(
      options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(bookmark, forKey: bookmarkKey(for: url.path))
    return beginAccessing(url, for: url.path)
  }

  func restore(path: String) throws -> Bool {
    let normalizedPath = normalizedURL(for: path).path
    if accessedURLs[normalizedPath] != nil {
      return true
    }
    guard let bookmark = defaults.data(forKey: bookmarkKey(for: normalizedPath)) else {
      return false
    }

    var isStale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    guard beginAccessing(url, for: normalizedPath) else {
      return false
    }

    if isStale {
      let refreshedBookmark = try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      defaults.set(refreshedBookmark, forKey: bookmarkKey(for: normalizedPath))
    }
    return true
  }

  func revoke(path: String) {
    let normalizedPath = normalizedURL(for: path).path
    if let url = accessedURLs.removeValue(forKey: normalizedPath) {
      url.stopAccessingSecurityScopedResource()
    }
    defaults.removeObject(forKey: bookmarkKey(for: normalizedPath))
  }

  private func beginAccessing(_ url: URL, for path: String) -> Bool {
    if accessedURLs[path] != nil {
      return true
    }
    guard url.startAccessingSecurityScopedResource() else {
      return false
    }
    accessedURLs[path] = url
    return true
  }

  private func normalizedURL(for path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
  }

  private func bookmarkKey(for path: String) -> String {
    keyPrefix + Data(path.utf8).base64EncodedString()
  }
}
