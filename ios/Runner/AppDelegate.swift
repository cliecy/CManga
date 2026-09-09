import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation // 添加此行
import VeneraImageAI

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?
  private var platformRegistrar: FlutterPluginRegistrar?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let imageAIRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "VeneraImageAIPlugin"),
          let platformRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "VeneraPlatformMethods") else {
      fatalError("Unable to register the native image AI plugin")
    }
    VeneraImageAIPlugin.register(with: imageAIRegistrar)
    self.platformRegistrar = platformRegistrar


    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    methodChannel.setMethodCallHandler { (call, result) in
      if call.method == "getProxy" {
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
          let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
          let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
          let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
          let proxyConfig = "\(host):\(port)"
          result(proxyConfig)
        } else {
          result("")
        }
      } else if call.method == "setScreenOn" {
        if let arguments = call.arguments as? Bool {
          let screenOn = arguments
          UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        result(nil)
      } else if call.method == "getDirectoryPath" {
        self.flutterResult = result
        self.getDirectoryPath()
      } else if call.method == "stopAccessingSecurityScopedResource" {
        self.directoryPath?.stopAccessingSecurityScopedResource()
        self.directoryPath = nil
        result(nil)
      } else if call.method == "selectDirectory" {
        guard let controller = self.platformRegistrar?.viewController else {
          result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "The Flutter view is not available", details: nil))
          return
        }
        self.directoryPicker = DirectoryPicker()
        self.directoryPicker?.selectDirectory(from: controller, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

  }

  func getDirectoryPath() {
    guard let rootViewController = platformRegistrar?.viewController else {
      flutterResult?(FlutterError(code: "NO_VIEW_CONTROLLER", message: "The Flutter view is not available", details: nil))
      flutterResult = nil
      return
    }
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    rootViewController.present(documentPicker, animated: true, completion: nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    self.directoryPath = urls.first
    if self.directoryPath == nil {
      flutterResult?(nil)
      return
    }

    let success = self.directoryPath.startAccessingSecurityScopedResource()

    if success {
      flutterResult?(self.directoryPath.path)
    } else {
      flutterResult?(nil)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil)
  }
}
