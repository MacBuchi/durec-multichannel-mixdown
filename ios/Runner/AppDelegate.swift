import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DurecmixFiles") {
      DocumentFiles.shared.register(with: registrar.messenger())
    }
  }
}

/// Files-app access for multi-GB DUREC WAVs, mirroring the Android SAF
/// bridge: recordings are opened in place (`asCopy: false`) under a
/// security scope that stays open for the whole session — the Rust engine
/// reopens the file by path on every call — and finished exports are moved
/// out of tmp with the export picker. Nothing is ever copied.
class DocumentFiles: NSObject, UIDocumentPickerDelegate {
  static let shared = DocumentFiles()

  private var pendingResult: FlutterResult?
  private var picking: Mode = .open
  /// Security scopes held open for the engine, keyed by path.
  private var scopedUrls: [String: URL] = [:]

  private enum Mode { case open, export }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "durecmix/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickWav":
      present(mode: .open, urls: nil, result: result)
    case "exportMove":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "args", message: "path required", details: nil))
        return
      }
      present(mode: .export, urls: [URL(fileURLWithPath: path)], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var rootController: UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
  }

  private func present(mode: Mode, urls: [URL]?, result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "picker already open", details: nil))
      return
    }
    guard let root = rootController else {
      result(FlutterError(code: "no_ui", message: "no root view controller", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    switch mode {
    case .open:
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [UTType.wav, UTType.audio], asCopy: false)
    case .export:
      picker = UIDocumentPickerViewController(forExporting: urls ?? [], asCopy: false)
    }
    pendingResult = result
    picking = mode
    picker.delegate = self
    root.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    if picking == .open {
      // Keep the scope open: releasing it would break the engine's per-call
      // reopen. One scope per file; iOS reclaims them when the app exits.
      if url.startAccessingSecurityScopedResource() {
        scopedUrls[url.path] = url
      }
    }
    result(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(nil)
    pendingResult = nil
  }
}
