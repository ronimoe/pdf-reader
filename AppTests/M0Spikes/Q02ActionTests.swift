import AppKit
import PDFKit
import Testing

nonisolated let contextMenuResults = Locked<[String: (hasOpen: Bool, delegate: [String], workspace: [String], page: Int)]>([:])

extension M0bSpikes {
    /// Q2: how link actions are exposed, what PDFKit does on a click, and
    /// whether a PDFView subclass can take clicks over completely.
    @Suite struct Q2Actions {
        func linksDocument() throws -> PDFDocument {
            try #require(PDFDocument(data: SpikeFixtures.links()))
        }

        func link(_ tag: String, in document: PDFDocument) throws -> PDFAnnotation {
            try #require(document.page(at: 0)?.annotations.first { $0.contents == tag })
        }

        @Test func actionTypesAsExposedByPDFKit() throws {
            let document = try linksDocument()
            var observed: [String: String] = [:]
            for spec in SpikeFixtures.linkSpecs {
                let annotation = try link(spec.tag, in: document)
                let actionClass = annotation.action.map { String(describing: type(of: $0)) } ?? "nil"
                let destination = annotation.destination.map { d in
                    "page \(document.index(for: d.page!)) point \(d.point) zoom \(d.zoom)"
                } ?? "nil"
                observed[spec.tag] = "\(actionClass) \(annotation.action?.type ?? "-")"
                let raw = annotation.annotationKeyValues.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
                SpikeLog.note("Q2", "\(spec.tag): action=\(actionClass) type=\(annotation.action?.type ?? "-") url=\(String(describing: annotation.url)) dest=\(destination) keys=[\(raw)]")
            }
            let expected: [String: String] = [
                "uri-custom": "PDFActionURL URI",
                "uri-https": "PDFActionURL URI",
                "goto-explicit": "PDFActionGoTo GoTo",
                "goto-named": "PDFActionGoTo GoTo",
                "dest-fit": "PDFActionGoTo GoTo",       // a bare /Dest is wrapped in a GoTo action
                "dest-named": "PDFActionGoTo GoTo",
                "gotor": "PDFActionRemoteGoTo GoToR",
                "launch": "PDFActionURL Launch",        // URL action class, nil URL
                "submit": "PDFAction SubmitForm",       // bare base class
                "javascript": "PDFAction JavaScript",   // bare base class
                "named-next": "PDFActionNamed Named",
                "named-print": "PDFActionNamed Named",
                "reset-form": "PDFActionResetForm ResetForm",
                "goto-xyz-null": "PDFActionGoTo GoTo",
                "goto-fith": "PDFActionGoTo GoTo",
                "goto-fitr": "PDFActionGoTo GoTo",
                "goto-xyz-zoom": "PDFActionGoTo GoTo",
            ]
            // Launch is a URL action whose URL is nil: classify by `type`, never by class.
            #expect(try link("launch", in: document).action?.type == "Launch")
            #expect((try link("launch", in: document).action as? PDFActionURL)?.url == nil)
            #expect(observed == expected)
        }

        struct ClickResult: CustomStringConvertible {
            var page = -1, performed: [String] = [], wentTo: [Int] = [], delegate: [String] = []
            var workspace: [String] = [], mouseDowns = 0, mouseUps = 0, hitView = ""
            var description: String {
                "page=\(page) perform=\(performed) goTo=\(wentTo) delegate=\(delegate) workspace=\(workspace) down=\(mouseDowns) up=\(mouseUps) hit=\(hitView)"
            }
        }

        /// One click on a fresh, stock PDFView (via a recording subclass).
        func defaultClick(_ tag: String, withDelegate: Bool) throws -> ClickResult {
            WorkspaceTripwire.shared.install()
            WorkspaceTripwire.shared.reset()
            let document = try linksDocument()
            let view = ProbePDFView(frame: .zero)
            let delegate = ProbeViewDelegate()
            if withDelegate { view.delegate = delegate }
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document)
            let point = view.windowPoint(centerOf: try link(tag, in: document))
            var result = ClickResult()
            result.hitView = host.window.contentView?.hitTest(view.superview?.convert(point, from: nil) ?? point).map { String(describing: type(of: $0)) } ?? "nil"
            view.performed.removeAll(); view.wentTo.removeAll()
            Synth.click(at: point, in: host.window)
            Spin.runLoop(0.3)
            result.page = view.currentPage.map { document.index(for: $0) } ?? -1
            result.performed = view.performed
            result.wentTo = view.wentTo
            result.delegate = delegate.calls
            result.workspace = WorkspaceTripwire.shared.calls
            result.mouseDowns = view.mouseDowns
            result.mouseUps = view.mouseUps
            return result
        }

        @Test func defaultClickBehaviourWithDelegate() throws {
            var results: [String: ClickResult] = [:]
            for spec in SpikeFixtures.linkSpecs where spec.clickable {
                let result = try defaultClick(spec.tag, withDelegate: true)
                results[spec.tag] = result
                SpikeLog.note("Q2", "default click \(spec.tag) (delegate): \(result)")
            }
            // Clicks reach the PDFView subclass itself (no inner view eats them).
            #expect(results.values.allSatisfy { $0.mouseDowns == 1 })
            // With a delegate, nothing ever reaches NSWorkspace.
            #expect(results.values.allSatisfy { $0.workspace.isEmpty })
            // URI links go to the delegate instead of opening.
            #expect(results["uri-custom"]?.delegate == ["willClickOnLink lectern-probe-unhandled://uri-link"])
            #expect(results["uri-https"]?.delegate == ["willClickOnLink https://lectern-probe.invalid/page"])
            // GoTo links navigate by themselves.
            #expect(results["goto-explicit"]?.page == 2)
            #expect(results["dest-fit"]?.page == 1)
            #expect(results["dest-named"]?.page == 1)
            #expect(results["goto-named"]?.page == 1)
            // GoToR goes to the remote-GoTo delegate method.
            #expect(results["gotor"]?.delegate == ["openPDFForRemoteGoTo nil URL"])
            // Launch, SubmitForm and JavaScript do nothing observable.
            for tag in ["launch", "submit", "javascript"] {
                #expect(results[tag]?.page == 0, "\(tag)")
                #expect(results[tag]?.delegate.isEmpty == true, "\(tag)")
            }
        }

        @Test func defaultURIClickWithoutDelegateCallsNSWorkspace() throws {
            let result = try defaultClick("uri-custom", withDelegate: false)
            SpikeLog.note("Q2", "default click uri-custom (no delegate): \(result)")
            #expect(result.workspace.count == 1)
            #expect(result.workspace.first?.contains("lectern-probe-unhandled://uri-link") == true)
        }

        @Test func defaultLaunchAndGoToRWithoutDelegate() throws {
            for tag in ["launch", "gotor", "submit", "javascript"] {
                let result = try defaultClick(tag, withDelegate: false)
                SpikeLog.note("Q2", "default click \(tag) (no delegate): \(result)")
                #expect(result.workspace.isEmpty, "\(tag)")
                #expect(result.page == 0, "\(tag)")
            }
        }

        @Test func linkFiresDuringMouseDown() throws {
            let document = try linksDocument()
            let view = ProbePDFView(frame: .zero)
            let delegate = ProbeViewDelegate()
            view.delegate = delegate
            let host = OffscreenHost(content: view)
            defer { host.close() }
            view.spikeLoad(document)
            let point = view.windowPoint(centerOf: try link("goto-explicit", in: document))
            let target = try #require(Synth.hitView(at: point, in: host.window))
            NSApp.postEvent(Synth.cgMouse(.leftMouseUp, at: point, in: host.window), atStart: true)
            target.mouseDown(with: Synth.mouse(.leftMouseDown, at: point, in: host.window))
            let performedDuringDown = view.performed
            let upStillQueued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil
            SpikeLog.note("Q2", "hit view=\(type(of: target)) performed during mouseDown=\(performedDuringDown) mouseUp still queued=\(upStillQueued)")
            #expect(String(describing: type(of: target)) == "PDFPageView")
            // PDFView.mouseDown → PDFViewController trackMouse:forAnnotation:
            // performs the action before mouseDown returns, without consuming
            // the queued mouse-up (it doesn't pull events from the queue).
            #expect(performedDuringDown == ["GoTo"])
            #expect(upStillQueued == true)
        }

        func rightClickMenu(_ view: PDFView, at point: NSPoint, in window: NSWindow) -> NSMenu? {
            let event = Synth.mouse(.rightMouseDown, at: point, in: window)
            return Synth.hitView(at: point, in: window)?.menu(for: event) ?? view.menu(for: event)
        }

        @Test(arguments: ["uri-https", "uri-custom", "goto-explicit"])
        func contextMenuOverLink(tag: String) throws {
            WorkspaceTripwire.shared.install()
            for withDelegate in [false, true] {
                WorkspaceTripwire.shared.reset()
                let document = try linksDocument()
                let view = ProbePDFView(frame: .zero)
                let delegate = ProbeViewDelegate()
                if withDelegate { view.delegate = delegate }
                let host = OffscreenHost(content: view)
                defer { host.close() }
                view.spikeLoad(document)
                let point = view.windowPoint(centerOf: try link(tag, in: document))
                let menu = try #require(rightClickMenu(view, at: point, in: host.window))
                let items = menu.items.map { "\($0.title)=\($0.action.map(NSStringFromSelector) ?? "-")" }
                SpikeLog.note("Q2", "context menu over \(tag) (delegate=\(withDelegate)): \(items)")
                let open = menu.items.first { $0.action == NSSelectorFromString("openRepresentedLink:") }
                if let open, let action = open.action {
                    NSApp.sendAction(action, to: open.target ?? view, from: open)
                    Spin.runLoop(0.2)
                }
                let page = view.currentPage.map { document.index(for: $0) } ?? -1
                SpikeLog.note("Q2", "after Open Link on \(tag) (delegate=\(withDelegate)): page=\(page) perform=\(view.performed) delegate=\(delegate.calls) workspace=\(WorkspaceTripwire.shared.calls)")
                contextMenuResults.withLock { $0["\(tag) delegate=\(withDelegate)"] = (open != nil, delegate.calls, WorkspaceTripwire.shared.calls, page) }
            }
        }

        @Test func contextMenuHasNoLinkItemsHeadless() throws {
            // Runs after the parameterised test above (the suite is serialized).
            let r = contextMenuResults.current
            #expect(r.count == 6)
            #expect(r.values.allSatisfy { !$0.hasOpen && $0.delegate.isEmpty && $0.workspace.isEmpty })
        }

        /// The private menu action behind PDFKit's "Open Link" item, called
        /// directly with each kind of represented object it might carry.
        @Test func privateOpenRepresentedLinkAction() throws {
            WorkspaceTripwire.shared.install()
            let selector = NSSelectorFromString("openRepresentedLink:")
            #expect(PDFView.instancesRespond(to: selector))
            let document = try linksDocument()
            let annotation = try link("uri-https", in: document)
            let candidates: [(String, Any)] = [
                ("URL", URL(string: "https://lectern-probe.invalid/page")!),
                ("annotation", annotation),
                ("action", annotation.action!),
            ]
            var outcomes: [String: String] = [:]
            for (label, object) in candidates {
                for withDelegate in [false, true] {
                    WorkspaceTripwire.shared.reset()
                    let view = ProbePDFView(frame: .zero)
                    let delegate = ProbeViewDelegate()
                    if withDelegate { view.delegate = delegate }
                    let host = OffscreenHost(content: view)
                    defer { host.close() }
                    view.spikeLoad(document)
                    let item = NSMenuItem(title: "Open Link", action: selector, keyEquivalent: "")
                    item.representedObject = object
                    view.perform(selector, with: item)
                    Spin.runLoop(0.2)
                    let outcome = "perform=\(view.performed) delegate=\(delegate.calls) workspace=\(WorkspaceTripwire.shared.calls)"
                    outcomes["\(label) delegate=\(withDelegate)"] = outcome
                    SpikeLog.note("Q2", "openRepresentedLink: with \(label) (delegate=\(withDelegate)): \(outcome)")
                }
            }
            // With a URL it goes straight to NSWorkspace, skipping the
            // delegate's PDFViewWillClickOnLink: even when a delegate is set.
            #expect(outcomes["URL delegate=true"] == "perform=[] delegate=[] workspace=[\"openURL: https://lectern-probe.invalid/page\"]")
            #expect(outcomes["URL delegate=false"] == "perform=[] delegate=[] workspace=[\"openURL: https://lectern-probe.invalid/page\"]")
            for key in ["annotation delegate=true", "annotation delegate=false", "action delegate=true", "action delegate=false"] {
                #expect(outcomes[key] == "perform=[] delegate=[] workspace=[]", "\(key)")
            }
        }

        /// performAction: as a choke point: calling it directly (as any
        /// untested activation path would) still goes through the policy.
        @Test func performActionChokePoint() throws {
            let s = try makeIntercepting()
            defer { s.host.close() }
            for spec in SpikeFixtures.linkSpecs {
                s.view.perform(try #require(try link(spec.tag, in: s.document).action))
            }
            Spin.runLoop(0.2)
            #expect(s.view.routed.count == SpikeFixtures.linkSpecs.count)
            #expect(s.delegate.calls.isEmpty)
            #expect(s.opener.opened.isEmpty)
            #expect(WorkspaceTripwire.shared.calls.isEmpty)
        }

        @Test func privateLinkMenuMethodsExist() {
            for name in ["openRepresentedLink:", "copyLink:", "_addOpenItemsToMenu:onPage:atPagePoint:"] {
                #expect(PDFView.instancesRespond(to: NSSelectorFromString(name)), "\(name)")
            }
        }

        @Test func interceptingViewOverridesOpenRepresentedLink() throws {
            let s = try makeIntercepting()
            defer { s.host.close() }
            let selector = NSSelectorFromString("openRepresentedLink:")
            let item = NSMenuItem(title: "Open Link", action: selector, keyEquivalent: "")
            item.representedObject = URL(string: "https://lectern-probe.invalid/page")!
            s.view.perform(selector, with: item)
            Spin.runLoop(0.1)
            #expect(WorkspaceTripwire.shared.calls.isEmpty)
            #expect(s.opener.opened.isEmpty)
            #expect(s.view.routed == [.web(URL(string: "https://lectern-probe.invalid/page")!)])
        }

        @Test func interceptingViewCanStripOpenLinkFromContextMenu() throws {
            let s = try makeIntercepting()
            defer { s.host.close() }
            let point = s.view.windowPoint(centerOf: try link("uri-custom", in: s.document))
            let menu = try #require(rightClickMenu(s.view, at: point, in: s.host.window))
            #expect(!menu.items.contains { $0.action == NSSelectorFromString("openRepresentedLink:") })
        }

        // MARK: Interception

        struct Intercepted {
            let view: InterceptingPDFView
            let host: OffscreenHost
            let document: PDFDocument
            let opener: RecordingOpener
            let delegate: ProbeViewDelegate
        }

        func makeIntercepting() throws -> Intercepted {
            WorkspaceTripwire.shared.install()
            WorkspaceTripwire.shared.reset()
            let document = try linksDocument()
            let view = InterceptingPDFView(frame: .zero)
            let opener = RecordingOpener()
            let delegate = ProbeViewDelegate()
            view.opener = opener
            view.delegate = delegate
            let host = OffscreenHost(content: view)
            view.spikeLoad(document)
            return Intercepted(view: view, host: host, document: document, opener: opener, delegate: delegate)
        }

        @Test func mouseDownOverrideTakesOverEveryLinkClick() throws {
            for spec in SpikeFixtures.linkSpecs where spec.clickable {
                let s = try makeIntercepting()
                defer { s.host.close() }
                s.view.go(to: s.document.page(at: 0)!)
                Spin.runLoop(0.1)
                Synth.click(at: s.view.windowPoint(centerOf: try link(spec.tag, in: s.document)), in: s.host.window)
                Spin.runLoop(0.2)
                let page = s.view.currentPage.map { s.document.index(for: $0) } ?? -1
                SpikeLog.note("Q2", "intercepted \(spec.tag): routed=\(s.view.routed) page=\(page) delegate=\(s.delegate.calls) opener=\(s.opener.opened) workspace=\(WorkspaceTripwire.shared.calls)")
                #expect(s.view.routed.count == 1, "\(spec.tag)")
                #expect(s.delegate.calls.isEmpty, "\(spec.tag): PDFKit's own link handling ran")
                #expect(s.opener.opened.isEmpty, "\(spec.tag)")
                #expect(WorkspaceTripwire.shared.calls.isEmpty, "\(spec.tag)")
                if case let .destination(index)? = s.view.routed.first {
                    #expect(page == index, "\(spec.tag)")
                } else {
                    #expect(page == 0, "\(spec.tag): page changed without our router")
                }
            }
        }

        @Test func uriOpensOnlyWhenPolicyAllows() throws {
            let s = try makeIntercepting()
            defer { s.host.close() }
            let https = s.view.windowPoint(centerOf: try link("uri-https", in: s.document))
            let custom = s.view.windowPoint(centerOf: try link("uri-custom", in: s.document))

            Synth.click(at: https, in: s.host.window)
            #expect(s.opener.opened.isEmpty)

            s.view.allowURL = { $0.scheme == "https" }
            Synth.click(at: https, in: s.host.window)
            Synth.click(at: custom, in: s.host.window)
            #expect(s.opener.opened == [URL(string: "https://lectern-probe.invalid/page")!])
            #expect(s.view.routed == [
                .web(URL(string: "https://lectern-probe.invalid/page")!),
                .web(URL(string: "https://lectern-probe.invalid/page")!),
                .otherScheme(URL(string: "lectern-probe-unhandled://uri-link")!),
            ])
            #expect(s.delegate.calls.isEmpty)
            #expect(WorkspaceTripwire.shared.calls.isEmpty)
        }

        @Test func interceptedGoToRecordsHistory() throws {
            let s = try makeIntercepting()
            defer { s.host.close() }
            Synth.click(at: s.view.windowPoint(centerOf: try link("goto-explicit", in: s.document)), in: s.host.window)
            #expect(s.view.routed == [.destination(pageIndex: 2)])
            #expect(s.view.history == [0])
            #expect(s.view.currentPage.map { s.document.index(for: $0) } == 2)
        }

        @Test func classifierCoversEveryFixtureLink() throws {
            let document = try linksDocument()
            var classified: [String: LinkTarget] = [:]
            for spec in SpikeFixtures.linkSpecs {
                classified[spec.tag] = LinkClassifier.classify(try link(spec.tag, in: document))
            }
            #expect(classified["uri-https"] == .web(URL(string: "https://lectern-probe.invalid/page")!))
            #expect(classified["uri-custom"] == .otherScheme(URL(string: "lectern-probe-unhandled://uri-link")!))
            #expect(classified["goto-explicit"] == .destination(pageIndex: 2))
            #expect(classified["goto-named"] == .destination(pageIndex: 1))
            #expect(classified["dest-fit"] == .destination(pageIndex: 1))
            #expect(classified["dest-named"] == .destination(pageIndex: 1))
            #expect(classified["gotor"] == .blocked("GoToR"))
            #expect(classified["launch"] == .blocked("Launch"))
            #expect(classified["submit"] == .blocked("SubmitForm"))
            #expect(classified["javascript"] == .blocked("JavaScript"))
            #expect(classified["reset-form"] == .blocked("ResetForm"))
            #expect(classified["named-next"] == .named("1"))
        }
    }
}
