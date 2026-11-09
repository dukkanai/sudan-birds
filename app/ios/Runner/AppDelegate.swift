import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "AuthRestoreFence") {
      FlutterMethodChannel(name: "sudan_birds/auth_restore_fence",
                           binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
        guard let args = call.arguments as? [String: Any],
              let project = args["project"] as? String,
              project.range(of: "^[a-zA-Z0-9.-]{1,253}$", options: .regularExpression) != nil,
              project != ".", project != ".." else {
          result(FlutterError(code: "invalid_project", message: "Invalid auth scope", details: nil))
          return
        }
        do {
          let fm = FileManager.default
          var directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("sudan_birds_auth_fences", isDirectory: true)
          try fm.createDirectory(at: directory, withIntermediateDirectories: true)
          // Nonsecret permission only. Excluding the directory also protects a
          // newly atomically replaced file before its own attributes are set.
          var flags = URLResourceValues()
          flags.isExcludedFromBackup = true
          try directory.setResourceValues(flags)
          var file = directory.appendingPathComponent(project + ".fence")
          switch call.method {
          case "read":
            if !fm.fileExists(atPath: file.path) { result(false); return }
            let data = try Data(contentsOf: file)
            result(data == Data("allow-v1".utf8))
          case "write":
            guard let allowed = args["allowed"] as? Bool else {
              result(FlutterError(code: "invalid_value", message: "Invalid fence", details: nil))
              return
            }
            let data = Data((allowed ? "allow-v1" : "block-v1").utf8)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try file.setResourceValues(flags)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
            result(try Data(contentsOf: file) == data)
          default: result(FlutterMethodNotImplemented)
          }
        } catch {
          result(FlutterError(code: "fence_unavailable", message: "Auth restore fence unavailable", details: nil))
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
