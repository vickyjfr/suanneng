import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var pendingExport: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "se9/file_export", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "export" else { result(FlutterMethodNotImplemented); return }
        guard let self = self, self.pendingExport == nil else {
          result(FlutterError(code: "EXPORT_BUSY", message: "Another export is active", details: nil)); return
        }
        guard let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
          result(FlutterError(code: "INVALID_PATH", message: "Missing file path", details: nil)); return
        }
        let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        guard source.path.hasPrefix(home), FileManager.default.fileExists(atPath: source.path) else {
          result(FlutterError(code: "INVALID_PATH", message: "Export source unavailable", details: nil)); return
        }
        self.pendingExport = result
        let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
        picker.delegate = self
        controller.present(picker, animated: true)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    pendingExport?(urls.first?.absoluteString)
    pendingExport = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingExport?(nil)
    pendingExport = nil
  }
}
