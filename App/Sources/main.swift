import AppKit

// The first NSDocumentController created becomes the shared one, so the
// subclass has to exist before AppKit makes the default during launch.
_ = ReaderDocumentController()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.mainMenu = MainMenu.make()
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
