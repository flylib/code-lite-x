import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // File → Open:原生"选择文件夹"面板。取消时回传 nil。
    let dialogs = FlutterMethodChannel(
      name: "codelitex/dialogs",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    dialogs.setMethodCallHandler { [weak self] call, result in
      if call.method == "pickSavePath" {
        // Git → Create Patch:原生"存储为"面板。取消时回传 nil。
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let args = call.arguments as? [String: Any], let name = args["name"] as? String {
          panel.nameFieldStringValue = name
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
          result(response == .OK ? panel.url?.path : nil)
        }
        if let window = self {
          panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
          finish(panel.runModal())
        }
        return
      }
      guard call.method == "pickDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "Open"
      panel.message = "Choose a project folder"
      let finish: (NSApplication.ModalResponse) -> Void = { response in
        result(response == .OK ? panel.url?.path : nil)
      }
      if let window = self {
        panel.beginSheetModal(for: window, completionHandler: finish)
      } else {
        finish(panel.runModal())
      }
    }

    super.awakeFromNib()
  }
}
