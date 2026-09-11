import Cocoa
import FlutterMacOS
import CMangaImageAI

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    CMangaImageAIPlugin.register(with: flutterViewController.registrar(forPlugin: "CMangaImageAIPlugin"))

    super.awakeFromNib()
  }
}
