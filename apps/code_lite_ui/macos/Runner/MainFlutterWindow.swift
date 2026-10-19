import Cocoa
import FlutterMacOS

/// Flutter 标题栏的高度(见 title_bar_widget.dart):红绿灯要在它里面垂直居中。
private let flutterTitleBarHeight: CGFloat = 40

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 标题栏透明、内容铺满整个窗口:系统自带的红黄绿按钮(真正的关闭 / 最小化 / 缩放)浮在 Flutter 画的标题栏上。
    // 标题栏空白处的拖动和双击由 Flutter 那边通过 codelitex/window 通知过来。
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    setUpWindowChannel(flutterViewController.engine.binaryMessenger)
    observeWindowState()

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
      if call.method == "pickFile" {
        // 选一个文件(设置里的 make 路径等);可执行文件常在隐藏目录,显示隐藏文件
        let args = call.arguments as? [String: Any]
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        if let message = args?["message"] as? String { panel.message = message }
        if let dir = args?["directory"] as? String { panel.directoryURL = URL(fileURLWithPath: dir) }
        let done: (NSApplication.ModalResponse) -> Void = { response in
          result(response == .OK ? panel.url?.path : nil)
        }
        if let window = self {
          panel.beginSheetModal(for: window, completionHandler: done)
        } else {
          done(panel.runModal())
        }
        return
      }
      if call.method == "pickProject" {
        // File → Open:目录(项目)和单个文件都能选(同 IntelliJ)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder or a file"
        let done: (NSApplication.ModalResponse) -> Void = { response in
          result(response == .OK ? panel.url?.path : nil)
        }
        if let window = self {
          panel.beginSheetModal(for: window, completionHandler: done)
        } else {
          done(panel.runModal())
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
    // 此时红绿灯已经建好,等布局稳定后挪到标题栏中间
    DispatchQueue.main.async { [weak self] in self?.centerTrafficLights() }
  }

  // MARK: - 标题栏

  private func setUpWindowChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "codelitex/window", binaryMessenger: messenger)
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDrag":
        // 按着标题栏空白处拖:让系统接手拖动窗口(也会吸附、跨屏)
        if let event = NSApp.currentEvent { self.performDrag(with: event) }
        result(nil)
      case "toggleZoom":
        self.handleTitlebarDoubleClick()
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 双击标题栏:照系统设置(系统设置 ▸ 桌面与程序坞 ▸ 双击窗口的标题栏)缩放、最小化或什么也不做。
  private func handleTitlebarDoubleClick() {
    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
    switch action {
    case "Minimize": performMiniaturize(nil)
    case "None": break
    default: performZoom(nil)
    }
  }

  private func observeWindowState() {
    let center = NotificationCenter.default
    // 全屏时系统把红绿灯收起来,告诉 Flutter 不必再给它们留位置
    center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.windowChannel?.invokeMethod("fullScreen", arguments: true)
    }
    center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.windowChannel?.invokeMethod("fullScreen", arguments: false)
      DispatchQueue.main.async { self?.centerTrafficLights() }
    }
    // 系统在这些时候会重新排布标题栏,把红绿灯放回默认位置:再挪一次
    for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.centerTrafficLights()
      }
    }
  }

  /// 红绿灯默认按 28pt 的系统标题栏居中,我们的标题栏是 40pt:往下挪,和标题栏里的内容垂直对齐。
  private func centerTrafficLights() {
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for type in types {
      guard let button = standardWindowButton(type), let container = button.superview else { continue }
      var origin = button.frame.origin
      origin.y = container.frame.height - flutterTitleBarHeight / 2 - button.frame.height / 2
      button.setFrameOrigin(origin)
    }
  }
}
