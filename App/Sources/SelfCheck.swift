import AppKit
import PDFKit
import PDFSave
import Security
import Sparkle

/// `Lectern -LecternSelfCheck`: a headless check of a built app, for `scripts/release/verify-dmg`
/// (architecture §8).
///
/// `main.swift` calls it before anything else, so with the argument the app never creates
/// `NSApplication`: no window, no Dock icon, no alert, no menu bar, and no preference, session or
/// recent-documents state is read or written. It checks the bundle, the embedded frameworks, the
/// entitlements the running process actually has, that the sandbox is on (the kernel says the
/// process is sandboxed, and it runs in its container), and the PDF engine on a document made in
/// memory: PDFKit opens and draws it, and the incremental writer saves a highlight into it.
/// It prints one line per check and exits 0 only if every check passed.
///
/// Reaching `main` at all already shows dyld loaded Sparkle under the hardened runtime.
/// libsystem_sandbox: 1 when the process `pid` is sandboxed (no filter: any operation).
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

enum SelfCheck {
    static let argument = "-LecternSelfCheck"

    struct Check: Equatable {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// Runs the check and exits when the argument is present; returns otherwise.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(argument) else { return }
        let checks = run(bundle: .main)
        for check in checks {
            print("selfcheck: \(check.passed ? "ok  " : "FAIL") \(check.name): \(check.detail)")
        }
        let passed = checks.allSatisfy(\.passed)
        print("selfcheck: \(passed ? "PASS" : "FAIL") (\(checks.filter(\.passed).count) of \(checks.count) checks passed)")
        fflush(stdout)
        exit(passed ? 0 : 1)
    }

    /// The entitlements a release build must have, and the one it must not.
    static let requiredEntitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.network.client",
        "com.apple.security.print",
        "com.apple.security.cs.disable-library-validation",
    ]
    static let forbiddenEntitlement = "com.apple.security.get-task-allow"

    static func run(bundle: Bundle) -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) { checks.append(Check(name: name, passed: passed, detail: detail)) }
        let info = bundle.infoDictionary ?? [:]

        // The bundle and what Info.plist promises.
        let identifier = bundle.bundleIdentifier ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        check("bundle", identifier == "io.github.ronimoe.Lectern" && !version.isEmpty && !build.isEmpty, "\(identifier) \(version) (\(build))")
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        let automatic = info["SUEnableAutomaticChecks"] as? Bool
        check("updates-opt-in", feed.hasPrefix("https://") && !key.isEmpty && automatic == false,
              "feed \(feed), EdDSA key \(key.isEmpty ? "missing" : "present"), Sparkle's own automatic checks \(automatic == false ? "off" : "NOT off")")
        let types = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let ranks = types.compactMap { $0["LSHandlerRank"] as? String }
        check("document-type", !ranks.isEmpty && ranks.allSatisfy { $0 == "Alternate" }, "PDF handler rank \(ranks)")

        // Licences and notices shipped in the app (GPL-3.0 §4–6; Sparkle's MIT notice).
        for (resource, needle) in [("LICENSE", "GNU GENERAL PUBLIC LICENSE"), ("Acknowledgements.txt", "Andy Matuschak"),
                                   ("known-limitations.md", "Known limitations")] {
            let text = AppResources.text(resource, in: bundle) ?? ""
            check("resource \(resource)", text.contains(needle), text.isEmpty ? "missing" : "\(text.utf8.count) bytes")
        }

        // Frameworks: Sparkle is the only one, at the pinned version.
        let sparkle = Bundle(for: SPUUpdater.self)
        let sparkleVersion = sparkle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let sparkleFolder = sparkle.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        check("sparkle", sparkleVersion == "2.10.1" && sparkleFolder == bundle.privateFrameworksURL?.standardizedFileURL.path,
              "Sparkle \(sparkleVersion) loaded from \(sparkle.bundleURL.path)")
        let frameworks = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.privateFrameworksPath ?? "")) ?? []).sorted()
        check("frameworks", frameworks == ["Sparkle.framework"], "Contents/Frameworks: \(frameworks)")

        // Entitlements of this running process, not of the file on disk.
        if let task = SecTaskCreateFromSelf(nil) {
            func value(_ name: String) -> Any? { SecTaskCopyValueForEntitlement(task, name as CFString, nil) }
            let missing = requiredEntitlements.filter { (value($0) as? Bool) != true }
            check("entitlements", missing.isEmpty, missing.isEmpty ? "all \(requiredEntitlements.count) present" : "missing \(missing)")
            check("no-get-task-allow", value(forbiddenEntitlement) == nil, value(forbiddenEntitlement) == nil ? "absent" : "present")
        } else {
            check("entitlements", false, "can't read this process's entitlements")
        }

        // The sandbox is on. (Reading a file outside the container was tried as a further probe and
        // dropped: started directly from a shell, as verify-dmg does, the read was allowed.)
        let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        let home = NSHomeDirectory()
        let sandboxed = sandbox_check(getpid(), nil, 0) == 1
        check("sandbox", sandboxed && container != nil && home.contains("/Library/Containers/\(identifier)"),
              "\(sandboxed ? "sandboxed" : "NOT sandboxed"), container \(container ?? "none"), home \(home)")

        // The PDF engine, on a document made here.
        checks += engineChecks()
        return checks
    }

    /// PDFKit opens, finds the text in and draws a two-page PDF made in memory, and the incremental
    /// writer appends a highlight that PDFKit then shows, with the original bytes as a prefix.
    static func engineChecks() -> [Check] {
        let phrase = "Lectern self-check"
        guard let original = makePDF(text: phrase), let document = PDFDocument(data: original), let page = document.page(at: 0) else {
            return [Check(name: "pdfkit", passed: false, detail: "couldn't make or open a PDF")]
        }
        var checks: [Check] = []
        let text = page.string ?? ""
        let drawn = drawsInk(page)
        checks.append(Check(name: "pdfkit", passed: document.pageCount == 2 && text.contains(phrase) && drawn,
                            detail: "\(document.pageCount) pages, text \(text.contains(phrase) ? "found" : "missing"), page 1 \(drawn ? "drawn" : "blank")"))
        guard let match = document.findString(phrase, withOptions: []).first else {
            checks.append(Check(name: "writer", passed: false, detail: "phrase not found"))
            return checks
        }
        let bounds = match.bounds(for: page)
        let change = AnnotationChange.addMarkup(NewMarkup(
            kind: .highlight, pageIndex: 0,
            quads: [Quad(rect: PDFRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))], contents: "self-check"))
        do {
            let result = try IncrementalWriter().saveInPlace(original: original, changes: [change])
            let reopened = PDFDocument(data: result.data)
            let highlights = reopened?.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count ?? 0
            let prefix = result.data.prefix(original.count) == original
            checks.append(Check(name: "writer", passed: prefix && highlights == 1,
                                detail: "\(original.count) → \(result.data.count) bytes, original \(prefix ? "intact" : "CHANGED"), \(highlights) highlight"))
        } catch {
            checks.append(Check(name: "writer", passed: false, detail: "\(error)"))
        }
        return checks
    }

    /// Two Letter pages, with a line of Helvetica text on the first.
    static func makePDF(text: String) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for index in 0..<2 {
            context.beginPDFPage(nil)
            if index == 0 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18),
                ]))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Draws `page` on white and reports whether anything but white came out.
    static func drawsInk(_ page: PDFPage) -> Bool {
        let width = 306, height = 396
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for offset in stride(from: 0, to: width * height * 4, by: 4) where pixels[offset] < 200 { return true }
        return false
    }
}
