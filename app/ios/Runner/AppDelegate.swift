import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var dictionaryFileAccess: IOSDictionaryFileAccess?
  private var dictionaryTextToSpeech: IOSDictionaryTextToSpeech?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    dictionaryFileAccess = IOSDictionaryFileAccess(messenger: messenger)
    dictionaryTextToSpeech = IOSDictionaryTextToSpeech(messenger: messenger)
  }
}

/// Owns iOS document-picker grants for dictionary folders. The selected URL is
/// kept active for the process lifetime and a minimal security-scoped bookmark
/// is saved so the same folder can be reopened after relaunch. Providers that
/// cannot grant persistent folder access fall back to a private Documents copy.
private final class IOSDictionaryFileAccess: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private struct ActiveAccess {
    let url: URL
    let hasSecurityScope: Bool
  }

  private static let channelName = "local_dictionary/file_access"
  private static let bookmarkKeyPrefix = "local_dictionary.read_bookmark."

  private let channel: FlutterMethodChannel
  private var activeAccessByPath: [String: ActiveAccess] = [:]
  private var pendingPickerResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    for access in activeAccessByPath.values where access.hasSecurityScope {
      access.url.stopAccessingSecurityScopedResource()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickDictionaryFolder":
      presentDictionaryFolderPicker(
        arguments: call.arguments as? [String: Any],
        result: result
      )
    case "saveReadBookmark":
      withPath(from: call, result: result) { path in
        do {
          result(try self.saveBookmark(forPath: path))
        } catch {
          result(self.flutterError(error))
        }
      }
    case "restoreReadBookmark":
      withPath(from: call, result: result) { path in
        do {
          result(try self.restoreBookmark(forPath: path))
        } catch {
          result(self.flutterError(error))
        }
      }
    case "revokeReadBookmark":
      withPath(from: call, result: result) { path in
        self.revokeBookmark(forPath: path)
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentDictionaryFolderPicker(
    arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard pendingPickerResult == nil else {
      result(
        FlutterError(
          code: "picker_busy",
          message: "Another dictionary folder picker is already open.",
          details: nil
        ))
      return
    }
    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "picker_unavailable",
          message: "The dictionary folder picker is not available yet.",
          details: nil
        ))
      return
    }

    pendingPickerResult = result
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder],
      asCopy: false
    )
    picker.delegate = self
    picker.presentationController?.delegate = self
    picker.allowsMultipleSelection = false
    if let initialPath = arguments?["initialDirectoryPath"] as? String,
      !initialPath.isEmpty
    {
      picker.directoryURL = URL(fileURLWithPath: initialPath, isDirectory: true)
    }
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicker(with: nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finishPicker(with: nil)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let selectedURL = urls.first else {
      finishPicker(with: nil)
      return
    }

    // Security scope belongs to the exact URL object returned by the picker.
    // Converting it to a standardized URL before starting access can discard
    // that capability on iOS file-provider URLs. Normalize only the dictionary
    // key and keep the original URL alive for all scoped access.
    let path = normalizedURL(forPath: selectedURL.path).path
    if isInsideApplicationContainer(selectedURL) {
      finishPickerSelection(path: path, wasCopiedIntoDictionaryHome: false)
      return
    }

    let hasSecurityScope = selectedURL.startAccessingSecurityScopedResource()
    activeAccessByPath[path] = ActiveAccess(
      url: selectedURL,
      hasSecurityScope: hasSecurityScope
    )

    if hasSecurityScope {
      do {
        guard try saveBookmark(forPath: path) else {
          throw CocoaError(.fileWriteUnknown)
        }
        finishPickerSelection(path: path, wasCopiedIntoDictionaryHome: false)
        return
      } catch {
        // Some third-party providers allow the current open operation but do
        // not support a durable folder bookmark. Preserve the user's import by
        // copying it into LumaLex's own Documents directory instead.
      }
    }

    copySelectedFolderIntoDictionaryHome(selectedURL, accessPath: path)
  }

  private func finishPicker(with value: Any?) {
    guard let result = pendingPickerResult else { return }
    pendingPickerResult = nil
    result(value)
  }

  private func saveBookmark(forPath path: String) throws -> Bool {
    let normalizedPath = normalizedURL(forPath: path).path
    guard let activeAccess = activeAccessByPath[normalizedPath] else {
      // Paths within the application container need no external grant.
      return FileManager.default.isReadableFile(atPath: normalizedPath)
    }
    let bookmark = try activeAccess.url.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    UserDefaults.standard.set(bookmark, forKey: bookmarkKey(forPath: normalizedPath))
    return true
  }

  private func restoreBookmark(forPath path: String) throws -> Bool {
    let normalizedPath = normalizedURL(forPath: path).path
    if activeAccessByPath[normalizedPath] != nil {
      return true
    }
    guard
      let bookmark = UserDefaults.standard.data(
        forKey: bookmarkKey(forPath: normalizedPath)
      )
    else {
      return FileManager.default.isReadableFile(atPath: normalizedPath)
    }

    var isStale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withoutUI, .withoutImplicitStartAccessing],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    let hasSecurityScope = url.startAccessingSecurityScopedResource()
    guard hasSecurityScope || FileManager.default.isReadableFile(atPath: url.path) else {
      return false
    }
    activeAccessByPath[normalizedPath] = ActiveAccess(
      url: url,
      hasSecurityScope: hasSecurityScope
    )

    if isStale {
      let refreshedBookmark = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(
        refreshedBookmark,
        forKey: bookmarkKey(forPath: normalizedPath)
      )
    }
    return true
  }

  private func finishPickerSelection(
    path: String,
    wasCopiedIntoDictionaryHome: Bool
  ) {
    finishPicker(
      with: [
        "path": path,
        "wasCopiedIntoDictionaryHome": wasCopiedIntoDictionaryHome,
      ]
    )
  }

  private func copySelectedFolderIntoDictionaryHome(
    _ sourceURL: URL,
    accessPath: String
  ) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let destination = try self.copyFolderIntoDictionaryHome(from: sourceURL)
        DispatchQueue.main.async {
          self.releaseActiveAccess(forPath: accessPath)
          self.finishPickerSelection(
            path: destination.path,
            wasCopiedIntoDictionaryHome: true
          )
        }
      } catch {
        DispatchQueue.main.async {
          self.releaseActiveAccess(forPath: accessPath)
          self.finishPicker(
            with: FlutterError(
              code: "file_access_copy_failed",
              message: "无法保持该文件夹的访问权限，也无法复制到 LumaLex/Dictionaries。请检查设备空间以及文件提供器的下载权限。",
              details: error.localizedDescription
            )
          )
        }
      }
    }
  }

  private func copyFolderIntoDictionaryHome(from sourceURL: URL) throws -> URL {
    let fileManager = FileManager.default
    guard let documentsURL = fileManager.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      throw CocoaError(.fileNoSuchFile)
    }

    let dictionaryHome = documentsURL.appendingPathComponent(
      "Dictionaries",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: dictionaryHome,
      withIntermediateDirectories: true
    )

    let selectedName = sourceURL.lastPathComponent.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let baseName = selectedName.isEmpty ? "Imported Dictionary" : selectedName
    var destination = dictionaryHome.appendingPathComponent(
      baseName,
      isDirectory: true
    )
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      destination = dictionaryHome.appendingPathComponent(
        "\(baseName) (\(suffix))",
        isDirectory: true
      )
      suffix += 1
    }

    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var copyError: Error?
    coordinator.coordinate(
      readingItemAt: sourceURL,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      do {
        try fileManager.copyItem(at: coordinatedURL, to: destination)
      } catch {
        copyError = error
      }
    }

    if let copyError {
      try? fileManager.removeItem(at: destination)
      throw copyError
    }
    if let coordinationError {
      try? fileManager.removeItem(at: destination)
      throw coordinationError
    }
    return destination.standardizedFileURL
  }

  private func releaseActiveAccess(forPath path: String) {
    guard let access = activeAccessByPath.removeValue(forKey: path) else {
      return
    }
    if access.hasSecurityScope {
      access.url.stopAccessingSecurityScopedResource()
    }
  }

  private func revokeBookmark(forPath path: String) {
    let normalizedPath = normalizedURL(forPath: path).path
    if let access = activeAccessByPath.removeValue(forKey: normalizedPath),
      access.hasSecurityScope
    {
      access.url.stopAccessingSecurityScopedResource()
    }
    UserDefaults.standard.removeObject(forKey: bookmarkKey(forPath: normalizedPath))
  }

  private func withPath(
    from call: FlutterMethodCall,
    result: @escaping FlutterResult,
    perform: (String) -> Void
  ) {
    guard let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "A dictionary folder path is required.",
          details: nil
        ))
      return
    }
    perform(path)
  }

  private func normalizedURL(forPath path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
  }

  private func isInsideApplicationContainer(_ url: URL) -> Bool {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return false
    }
    let containerPath = documentsURL.deletingLastPathComponent()
      .standardizedFileURL.path
    let candidatePath = normalizedURL(forPath: url.path).path
    return candidatePath == containerPath
      || candidatePath.hasPrefix(containerPath + "/")
  }

  private func bookmarkKey(forPath path: String) -> String {
    let encodedPath = Data(path.utf8).base64EncodedString()
    return Self.bookmarkKeyPrefix + encodedPath
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(
      code: "file_access",
      message: "无法保存或恢复所选词典文件夹的访问权限。",
      details: error.localizedDescription
    )
  }

  private func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    return visibleViewController(from: root)
  }

  private func visibleViewController(from controller: UIViewController?) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return visibleViewController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return visibleViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return visibleViewController(from: tab.selectedViewController)
    }
    if let split = controller as? UISplitViewController {
      return visibleViewController(from: split.viewControllers.last)
    }
    return controller
  }
}

private final class IOSDictionaryTextToSpeech {
  private static let channelName = "local_dictionary/text_to_speech"

  private let channel: FlutterMethodChannel
  private let synthesizer = AVSpeechSynthesizer()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "speak":
      guard let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        result(
          FlutterError(
            code: "invalid_text",
            message: "A non-empty example sentence is required.",
            details: nil
          ))
        return
      }
      let requestedLanguage =
        (arguments["locale"] as? String)?
        .replacingOccurrences(of: "_", with: "-") ?? "en-US"
      guard
        let voice = bestAvailableVoice(for: requestedLanguage)
          ?? bestAvailableVoice(for: "en-US")
      else {
        result(
          FlutterError(
            code: "language_missing",
            message: "未找到可用的英语系统语音。",
            details: nil
          ))
        return
      }
      NSLog(
        "%@",
        "LumaLex TTS voice: \(voice.name) [\(voice.language)] "
          + "quality=\(voice.quality.rawValue) id=\(voice.identifier)"
      )
      do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
          .playback,
          mode: .spokenAudio,
          options: [.duckOthers]
        )
        try audioSession.setActive(true)
      } catch {
        result(
          FlutterError(
            code: "audio_session_failed",
            message: "无法启动系统语音的音频会话。",
            details: error.localizedDescription
          ))
        return
      }
      synthesizer.stopSpeaking(at: .immediate)
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      synthesizer.speak(utterance)
      result(true)
    case "stop":
      synthesizer.stopSpeaking(at: .immediate)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Keeps the requested English region and only considers non-novelty,
  /// non-personal voices that the public API reports as available. A Siri
  /// voice is used opportunistically when the device exposes one; otherwise
  /// the highest-quality ordinary system voice wins. The system's ordering is
  /// retained as the tie-breaker between equivalent candidates.
  private func bestAvailableVoice(
    for requestedLanguage: String
  ) -> AVSpeechSynthesisVoice? {
    let language = Locale.canonicalLanguageIdentifier(
      from: requestedLanguage
    )
    let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter {
      Locale.canonicalLanguageIdentifier(from: $0.language)
        .caseInsensitiveCompare(language) == .orderedSame
        && !$0.voiceTraits.contains(.isNoveltyVoice)
        && !$0.voiceTraits.contains(.isPersonalVoice)
    }

    return matchingVoices.max { current, candidate in
      let currentIsSiri = isSiriVoice(current)
      let candidateIsSiri = isSiriVoice(candidate)
      if currentIsSiri != candidateIsSiri {
        return !currentIsSiri && candidateIsSiri
      }
      return voiceQualityRank(current.quality)
        < voiceQualityRank(candidate.quality)
    } ?? AVSpeechSynthesisVoice(language: language)
  }

  /// Apple doesn't publish fixed identifiers for Siri voices. Inspecting the
  /// public name and identifier of an already-available voice lets us prefer
  /// one without depending on a specific private identifier.
  private func isSiriVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
    voice.name.localizedCaseInsensitiveContains("siri")
      || voice.identifier.localizedCaseInsensitiveContains("siri")
  }

  private func voiceQualityRank(
    _ quality: AVSpeechSynthesisVoiceQuality
  ) -> Int {
    switch quality {
    case .premium:
      return 2
    case .enhanced:
      return 1
    default:
      return 0
    }
  }
}
