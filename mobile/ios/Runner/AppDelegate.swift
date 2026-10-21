import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var pendingExport: FlutterResult?
  private var exportDirectory: URL?

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
        let name = (arguments["name"] as? String ?? source.lastPathComponent) as NSString
        guard name.lastPathComponent == name as String, !name.lastPathComponent.isEmpty,
              name.lastPathComponent != ".", name.lastPathComponent != ".." else {
          result(FlutterError(code: "INVALID_PATH", message: "Invalid file name", details: nil)); return
        }
        self.pendingExport = result
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let named = directory.appendingPathComponent(name.lastPathComponent)
        self.exportDirectory = directory
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try FileManager.default.linkItem(at: source, to: named) }
            catch { try FileManager.default.copyItem(at: source, to: named) }
            DispatchQueue.main.async {
              let picker = UIDocumentPickerViewController(forExporting: [named], asCopy: true)
              picker.delegate = self
              controller.present(picker, animated: true)
            }
          } catch {
            DispatchQueue.main.async {
              self.pendingExport?(FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
              self.finishExport()
            }
          }
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    pendingExport?(urls.first?.absoluteString)
    finishExport()
  }

  private func finishExport() {
    pendingExport = nil
    if let directory = exportDirectory { try? FileManager.default.removeItem(at: directory) }
    exportDirectory = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingExport?(nil)
    finishExport()
  }
}
