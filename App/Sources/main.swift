import AppKit

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.mainMenu = MainMenu.make()
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
