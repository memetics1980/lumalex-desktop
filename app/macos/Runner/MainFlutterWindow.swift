import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopServices: DesktopServices?
  private let speech = AVSpeechSynthesizer()
  private var speechChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1120, height: 760))
    self.minSize = NSSize(width: 640, height: 480)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "local_dictionary/text_to_speech",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    speechChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "speak":
        guard let arguments = call.arguments as? [String: Any],
              let text = arguments["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 2000 else {
          result(FlutterError(code: "invalid_text", message: "Invalid speech text", details: nil))
          return
        }
        let locale = (arguments["locale"] as? String ?? "en-US")
          .replacingOccurrences(of: "_", with: "-")
        guard let voice = AVSpeechSynthesisVoice(language: locale) else {
          result(FlutterError(code: "voice_unavailable", message: "No voice for this language", details: nil))
          return
        }
        self.speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        self.speech.speak(utterance)
        result(true)
      case "stop":
        self.speech.stopSpeaking(at: .immediate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    desktopServices = DesktopServices(window: self, messenger: flutterViewController.engine.binaryMessenger)
    super.awakeFromNib()
  }
}
