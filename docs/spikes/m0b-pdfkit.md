# M0b: PDFKit behaviour, observed

**Branch:** `m0b-pdfkit`. **Machine:** Apple M3 Pro (11 cores, 18 GB), macOS 26.6.2 (25G83), Xcode 27.1 (27A9275). **Date:** 2026-10-29.

This spike replaces the PDFKit **[verify]** items in [architecture.md](../architecture.md) with observed behaviour. Every finding has an app-hosted Swift Testing test in `AppTests/M0Spikes/` that asserts what was observed, so a future PDFKit change fails the build. `./scripts/test.sh` passes, and it runs these tests headlessly.

## Summary

| # | Question | Result | Architecture |
|---|----------|--------|--------------|
| 1 | JavaScript | Never executed, from any trigger | Confirmed |
| 2 | Action types and clicks | All exposed; a `mouseDown` override owns every click | **Change:** the interception point and three extra leaks |
| 3 | Form fields | Event interception blocks editing; `isReadOnly` changes the bytes | Confirmed, with the Tab rule |
| 4 | Rotation | Always serialised; no view-only rotation exists | Confirmed |
| 5 | Annotation metadata | **`/T` = macOS full name and `/M` are filled automatically** | **Change:** B4 needs explicit clearing |
| 6 | Whole-file rewrite | Rewrites everything; drops a lot; **detaches form widgets** | **Change:** Save a Copy must not go through PDFKit |
| 7 | Preview popover | Sharing works; **live annotation changes reach only one view**; `/Fit` isn't honoured | **Change:** pane refresh and `/Fit` handling |
| 8 | Hover and Force Click | API fine; tracking-area delivery can't be tested headlessly | Confirmed, partly unverified |
| 9 | Thumbnails | 600 in 0.36 s on an actor; TSan clean | Confirmed |
| 10 | Search | Progressive, all callbacks on main, main thread free | Confirmed |
| 11 | Pixel checks | `PDFPage.draw` works; `cacheDisplay` misses annotations | Test-strategy note |

---

## 1. JavaScript

**Observed.** PDFKit never executes document JavaScript. The fixture (`SpikeFixtures.javaScriptProbe`) has one output field per trigger, each starting as `INITIAL`, and a script for each trigger that would set its field to `"JS" + "_RAN"`. The value is built by concatenation, so `JS_RAN` can only appear if a script ran. The triggers are:
- the catalog `/OpenAction` (which also sets `this.pageNum = 1`),
- a document-level `/Names /JavaScript` script,
- page-open `/AA /O`,
- a link's JavaScript `/A`,
- a field's focus (`/Fo`), keystroke (`/K`), mouse-up (`/U`) and blur (`/Bl`) actions,
- a plain calculate action (`/C`), an `AFSimple_Calculate`, and `AFNumber_Format`/`AFNumber_Keystroke`.

After loading, displaying (run loop spun 0.5 s), clicking the link, clicking the trigger field, typing into it, pressing Return, clicking away, and changing the calculation input through the API:
- every output is still `INITIAL`,
- the view stays on page 1,
- `JS_RAN` doesn't occur in `dataRepresentation()`,
- no `NSWorkspace` call is made.

A click on the JavaScript link reaches `PDFView.performAction:` with a `PDFAction` of type `JavaScript`, which does nothing.

**Evidence.** `Q1JavaScript.noJavaScriptRunsOnLoadDisplayClickFocusTypeOrBlur`, `Q1JavaScript.fixtureIsWellFormed`. Also `dataRepresentationStripsDocumentJavaScript`: the rewrite drops all JavaScript and every JavaScript trigger (`/OpenAction`, `/JavaScript`, `/JS`, `/AA`, `/Names`, `/CO`). The JavaScript link survives as a link with no action. Other link action types do survive a rewrite (§6).

**Architecture.** A4 "JavaScript is never executed" is **confirmed** with no work needed. Classify the action (§2) so the app can explain a JavaScript link when it's clicked.

## 2. Action types and link clicks

**How actions are exposed.** `PDFAnnotation.action` is never nil for a link:

| Action in the file | `type(of: action)` | `action.type` | Notes |
|---|---|---|---|
| `URI` | `PDFActionURL` | `URI` | `url` is set |
| `GoTo` (explicit or named) | `PDFActionGoTo` | `GoTo` | named destinations are resolved |
| bare `/Dest` (explicit or named) | `PDFActionGoTo` | `GoTo` | wrapped into a GoTo action |
| `GoToR` | `PDFActionRemoteGoTo` | `GoToR` | **`url` is declared non-optional but is nil** when the document has no file URL. Reading it from Swift traps (it crashed the test host). Read it with KVC. |
| `Launch` | **`PDFActionURL`** | `Launch` | `url` is nil, so a class-based check would treat it as a broken URI |
| `SubmitForm` | `PDFAction` (base class) | `SubmitForm` | |
| `JavaScript` | `PDFAction` (base class) | `JavaScript` | |
| `Named` | `PDFActionNamed` | `Named` | |
| `ResetForm` | `PDFActionResetForm` | `ResetForm` | |

Destination detail is in §7.

**What a stock `PDFView` does on a click.**
- The click hits an internal `PDFPageView`. It forwards `mouseDown:` up the responder chain to `PDFView.mouseDown:`, which goes to `PDFViewController mouseDown:`, then `trackMouse:forAnnotation:`, then `_annotationHit:`, then `-[PDFView performAction:]` (from a crash backtrace during the spike).
- **The action runs inside `mouseDown`, before it returns.** `mouseUp` plays no part.
- **`URI`:** goes to the delegate's `PDFViewWillClickOnLink:withURL:`. With no delegate, `PDFView`'s own implementation calls `NSWorkspace openURL:`. The tripwire caught it.
- **`GoTo`:** `performAction:` then `goToDestination:`, which navigates.
- **`GoToR`:** goes to the delegate's `PDFViewOpenPDF:forRemoteGoToAction:`. With no delegate, nothing observable happens; per the header, it beeps.
- **`Launch`, `SubmitForm`, `JavaScript`:** `performAction:` is called and nothing observable happens. No `NSWorkspace` call, no navigation, no delegate call.
- **`Named` and `ResetForm`:** go to `performAction:`.

**Three more ways a URL can leave, beyond the click:**
1. **`-[PDFView openRepresentedLink:]`** is a private action that, by its name, sits behind a context-menu "Open Link". Given an `NSMenuItem` whose `representedObject` is a URL, it calls `NSWorkspace openURL:` directly. **It skips the delegate even when one is set.** The headless context menu (`menuForEvent:`) showed no link items, so whether the real right-click menu offers them can't be verified here (unverified). `PDFView` does respond to `_addOpenItemsToMenu:onPage:atPagePoint:` and `copyLink:` (`privateLinkMenuMethodsExist`).
2. **The delegate's default implementation:** a `PDFView` with no delegate opens URI links itself.
3. **Force Click:** `PDFView` installs an `NSImmediateActionGestureRecognizer`, with itself as delegate, for Look Up and link previews. See §8.

**The interception point that works.** In a `PDFView` subclass (`InterceptingPDFView` in `LinkInterception.swift`):
- Override **`mouseDown(with:)`**. Hit-test with `page(for:nearest:)`, `convert(_:to:)` and `PDFPage.annotation(at:)`, and classify. On a link, **don't call super**. Route on the matching `mouseUp`.
- Override `menu(for:)` to drop `openRepresentedLink:` items.
- Implement **`@objc(openRepresentedLink:)`** to route through the same policy.
- Override **`perform(_:)`** as a choke point, classifying and routing without calling super. Every observed activation path except `openRepresentedLink:` ends in `-[PDFView performAction:]`. This also catches paths that can't be tested headlessly, such as VoiceOver pressing a link element. `performActionChokePoint` calls it with every fixture action: everything is routed, with no delegate call, no opener call and no `NSWorkspace` call.

With this in place, every fixture link was routed by our code, and none of PDFKit's own handling ran:
- no delegate call,
- no `performAction:`,
- no navigation except our own routed `go(to:)`, which records history,
- no `NSWorkspace` call.

A URI opens only through the `URLOpening` seam, and only when the policy allows it. `uriOpensOnlyWhenPolicyAllows`: with the policy denying, nothing opens. Allowing `https` opens exactly one URL, and the custom scheme is still held back.

**Evidence.** All in `Q2Actions`:
- `actionTypesAsExposedByPDFKit`
- `defaultClickBehaviourWithDelegate`
- `defaultURIClickWithoutDelegateCallsNSWorkspace`
- `defaultLaunchAndGoToRWithoutDelegate`
- `linkFiresDuringMouseDown`
- `privateOpenRepresentedLinkAction`
- `mouseDownOverrideTakesOverEveryLinkClick`
- `uriOpensOnlyWhenPolicyAllows`
- `interceptedGoToRecordsHistory`
- `interceptingViewOverridesOpenRepresentedLink`
- `performActionChokePoint`
- `privateLinkMenuMethodsExist`
- `classifierCoversEveryFixtureLink`

**Architecture: change to §4.4.** "Owning link clicks" should name the mechanism:
- **Intercept in `mouseDown`, not `mouseUp`** (PDFKit acts during `mouseDown`). Don't call super for link annotations.
- **Classify by `action.type`, never by class.** `Launch` arrives as `PDFActionURL`. Read `PDFActionRemoteGoTo.url` only through KVC.
- **Close the side doors:**
  - Override `perform(_:)` as the choke point; never call super for link actions.
  - Always set a delegate whose `PDFViewWillClickOnLink` routes through the policy.
  - Override `openRepresentedLink:`.
  - Filter link items out of the context menu.
  - Remove the immediate-action recognizer (§8).
- `LinkTarget` (§5) should carry the raw action type string for the "blocked" message.

## 3. Form fields

**Observed.**
- **Stock `PDFView`:**
  - A click on a text field starts editing. The first responder becomes a private `PDFTextWidgetTextView`, and typing changes `widgetStringValue` (`Alice` became `AliceZ`).
  - A click on a checkbox toggles `buttonWidgetState`.
- **Blocking without `isReadOnly`:** a `PDFView` subclass (`FormBlockingPDFView`) swallows `mouseDown` on widget annotations and swallows Tab in `keyDown`. Then:
  - no editor appears, and the first responder stays the view,
  - text values and the checkbox are unchanged,
  - `isReadOnly` is still false,
  - the rewritten bytes keep `/V (Alice)`.
- **Keyboard focus:**
  - Tab sent to the `PDFView` itself doesn't move focus into any field, even in a stock view.
  - Of the two paths tested, Tab and click, only a click gave a field focus. Other paths, such as accessibility, weren't tested.
  - Tab inside an editing field (synthesised and sent to the field editor) stayed in the same field. That differs from what `PDFView`'s private `handleTabInTextWidget:` suggests, so treat it as unverified for a real keyboard. It's moot once clicks are blocked, because no field ever gets focus.
- **`isReadOnly` changes `dataRepresentation()`:**
  - An untouched rewrite writes `/Ff 0` on every widget; the original had no `/Ff`.
  - With `isReadOnly = true` it writes `/Ff 1`.
  - `isReadOnly` also blocks editing in a stock view.

**Evidence.** All in `Q3Forms`:
- `stockPDFViewEditsFieldsOnClick`
- `tabFromPDFViewDoesNotEnterFields`
- `syntheticTabInsideAFieldStaysInThatField`
- `blockingViewPreventsClickAndTabEditing`
- `isReadOnlyChangesTheSerialisedFieldFlags`
- `isReadOnlyAlsoBlocksEditingInAStockView`

**Architecture.** §4.3 is **confirmed**: catch mouse and keyboard events, and never set `isReadOnly`. Add three points:
1. Swallow `mouseDown` on any `Widget` annotation, including buttons and choice fields.
2. Keep Tab and Shift-Tab for link focus mode (§4.4). Never pass them to `super` while a widget could be focused.
3. **Unverified:** whether VoiceOver can activate a widget through accessibility actions, bypassing events. Check this in the M5 accessibility pass.

The Q6 finding matters here too: PDFKit's own rewrite changes form structure even when nothing is touched.

## 4. Rotation

**Observed.**
- `PDFPage.rotation = 90` is written as `/Rotate 90` by both `dataRepresentation()` and `write(to:)`, and survives a reload. Setting it back to the original value writes `/Rotate 0` again.
- `PDFView` has no rotation API. Its only rotation selectors are private `previewRotatePage…` methods and the print `autoRotate` flags.
- A `PDFPage` subclass that overrides `rotation` (through `PDFDocument.pageClass`) does rotate the view's layout: the document view went from 628×811 to 808×631. But the writer reads the same getter, so it **writes `/Rotate 90`**. **There is no view-only rotation.**

**Evidence.** `Q4Rotation`: `rotationIsWrittenByDataRepresentationAndWrite`, `pdfViewHasNoRotationAPI`, `pageSubclassRotationOverride`.

**Architecture.** §4.3 and B9 are **confirmed**:
- rotation goes into the shared model, with the original per-page values recorded,
- the incremental writer never writes `/Rotate`,
- nothing serialises the on-screen `PDFDocument`.

Because the rotation is in the shared model, it applies to both panes, which matches B9 ("applies to the whole document"). Implementation note: in this MainActor-default target, `PDFPage` and `PDFDocument` subclasses must be declared `nonisolated`, or they don't compile.

## 5. Annotation metadata

**Observed.** **PDFKit fills in the author and date automatically.**
- **On creation:** `PDFAnnotation(bounds:forType:withProperties:nil)` sets `userName` to the macOS account's full name (`NSFullUserName()`) and `modificationDate` to now. In memory the keys are `/T`, `/M` and `/P`.
- **On serialisation:** every Highlight, Underline, StrikeOut and Text annotation is written with `/T (<full name>)`, `/M (D:…)`, a generated `/AP`, plus `/F`, `/Border`, `/DA` and `/C`. No `/NM` or `/CreationDate` is written.
- **Popups:** a Text note gets a Popup automatically. The Popup has its own `/M`.
- **Duplicates:** the Text annotation and its Popup are each **written twice**, as duplicate objects.
- **Clearing works:** setting `userName = nil` and `modificationDate = nil` removes `/T` and `/M` from the written annotation. The Popup's `/M` and `/T` have to be cleared separately. An explicit `userName` is written as `/T`.

**Evidence.** All in `Q5AnnotationMetadata`:
- `newAnnotationsGetAccountNameAndDateInMemory`
- `serialisationWritesAuthorDateAndAppearance`
- `clearingUserNameAndDateKeepsThemOutOfTheFile`
- `popupDateMustBeClearedSeparately`
- `explicitUserNameIsWrittenAsT`

**Architecture: change.** B4 says the author is "never filled in automatically from the macOS account". PDFKit does exactly that, so §4.3 "The author (B4)" must say:
- every new annotation, and its popup, has `userName` set explicitly: to the Settings value, or to nil when that is empty.
- `modificationDate` is set on purpose. The `/M` date isn't covered by any decision. It's harmless but identifying, so choose whether to keep it.
- The incremental writer (§3.2) serialises from `AnnotationChange`, not from PDFKit's dictionaries, so it controls `/T`, `/M`, `/NM` and `/AP` itself. Add a writer test that a new annotation never contains `NSFullUserName()`.

## 6. The whole-file rewrite

**Observed.** `dataRepresentation()` always rewrites the whole file. Even an unchanged document comes back different, and the original bytes are never a prefix. The fixture (`SpikeFixtures.incremental`) is a base revision plus an incremental update that replaces the page content and `/Info`. Its rewrite:

| Kept | Dropped or changed |
|------|--------------------|
| The latest page content ("Revision two"); the old revision is gone | Header becomes `%PDF-1.3` |
| `/Title` | One `%%EOF`, no `/Prev`: the revision history is gone |
| The form field value | Comments, and the unreferenced (orphan) object |
| Link actions PDFKit models (URI, GoTo, GoToR, Named, ResetForm) | Custom keys in the catalog, page, `/Info` and trailer |
| | `/ID`: both halves replaced with a new ID |
| | `/OpenAction`, `/PageLabels`, `/Names` |
| | All JavaScript, `/AA`, and `/CO` (Q1) |
| | `Launch`, `SubmitForm` and `JavaScript` link actions (the link stays, its action is dropped) |
| | `/Producer` becomes "macOS Version 26.6.2 … Quartz PDFContext" |
| | Size 1,853 → 15,112 bytes: fonts are re-embedded as subset TrueType |
| | No object streams or xref streams (a classic xref table) |

**Form damage.**
- The rewrite writes the AcroForm `/Fields` as **separate copies** of the widgets. The page's `/Annots` and `/Fields` share no objects; on the 12-field fixture, `/Fields` is objects 77–88 and the page widgets are 8–19.
- It also adds `/NeedAppearances true`, `/DV` and `/Ff 0`.
- `qpdf --check` (12.4.2, run by hand) reports "widget annotation is not reachable from /AcroForm" for every widget, on both rewritten form files.

**Evidence.** All in `Q6Rewrite`:
- `fixtureHasTwoRevisions`
- `unchangedDocumentIsStillRewritten`
- `rewriteOfIncrementallyUpdatedFile` (asserts the whole table above)
- `linkActionsAfterRewrite`
- `rewriteDetachesWidgetsFromAcroFormFields`

The outputs are saved to `~/Library/Containers/io.github.ronimoe.Lectern/Data/tmp/m0b-spikes/` for manual checks.

**Architecture: change.**
- §3.1 "Saving rewrites the whole file" is **confirmed**. So is the need for §3.2's appending writer.
- **§4.3's Save a Copy path can't use PDFKit's writer.** Even a fresh `PDFDocument` built from the original bytes loses page labels, the open action, `/ID`, custom metadata, and form structure. That breaks A5 (form data byte-identical) and §3.2 criterion 4.
- Save a Copy should be **the original bytes plus the incremental writer's appended section**, written to the new location.
- The §3.2 "Fallback if every candidate fails" (all saves through PDFKit) must list these losses as known limitations, and refuse or warn for documents with forms or signatures.

## 7. The preview popover: a second view on one document

**Observed.**
- **Sharing:** two `ReaderPDFView`s can share one `PDFDocument`. Both report the same document and current page. `PDFDocument.delegate` is a single slot shared by every view on the document; the panes don't set it.
- **Existing annotations** show in both views. This is measured by PDFKit's annotation effect layers under each view's `PDFPageView`, because offscreen pixel capture can't see annotations (§11).
- **Live changes reach only one view.**
  - `PDFPage` has a single private `view` slot, owned by the view that last laid the page out.
  - An annotation added or removed while both views are showing appears or disappears only in the owner. In every display-mode combination tested, the other view kept showing the old state.
  - `annotationsChanged(on:)`, `layoutDocumentView()`, `needsDisplay`, `go(to:)` and toggling the display mode don't refresh the stale view (`cheapRefreshesDoNotUpdateTheStaleView`, one case each).
  - **Reassigning `document`** (`nil`, then the same document) does refresh it. But that moves ownership, so the next change then misses the *other* view.
- **`go(to: PDFDestination)`:**
  - An explicit point lands exactly at the top of the view (`/XYZ 0 792`, `/XYZ 100 500`, constructed y=300).
  - The destination zoom is ignored: `/XYZ … 2` leaves the scale at 1.
  - `/Fit`, `/FitH 400`, `/FitR 72 72 300 300`, `/XYZ null null null`, and a point built from `kPDFDestinationUnspecifiedValue` are **all exposed as an unspecified point**, with the zoom unspecified too. PDFKit discards the `/FitH` top and the `/FitR` rectangle.
  - Each of those lands with the top of the page in view, keeps the current horizontal scroll, and **doesn't change the scale**. `/Fit` doesn't fit.
  - Showing the whole page needs `scaleFactor = scaleFactorForSizeToFit`; that gave 0.37 with the whole page visible in a 400×300 view.

**Evidence.** All in `Q7Preview`:
- `twoViewsCanShareOneDocument`
- `existingAnnotationsShowInBothViews`
- `liveAdditionReachesOnlyThePageOwner` (three display-mode pairs)
- `cheapRefreshesDoNotUpdateTheStaleView` (five refresh calls)
- `reassigningTheDocumentRefreshesTheStaleView`
- `removalReachesOnlyThePageOwnerToo`
- `goToDestinationVariants`
- `fitDestinationNeedsExplicitScaleForWholePage`

**Architecture: changes.**
- **§4.2 ("an annotation added in one appears in the other at once") isn't true for live changes.**
  - The popover is fine: it's created after the annotation exists, and it's transient.
  - Split panes (B3) need a refresh step. After any annotation add, edit or delete, every *other* pane showing an affected page must re-bind: capture the `ReadingAnchor`, set `document` to nil and back, restore the anchor.
  - The cost and flicker of that re-bind should be measured in M3.
  - Until then, treat this as a B3 risk, and look at whether one pane can render annotations as a page overlay (`PDFPageOverlayViewProvider`).
- **§4.4 and A3 preview:** read `PDFDestination.point`.
  - If either coordinate is `kPDFDestinationUnspecifiedValue`, treat the destination as "no usable position": fit the whole page with `scaleFactorForSizeToFit`.
  - Otherwise, scroll to the point at the current preview scale, ignoring the PDF zoom.
  - To mark a `/FitH` or `/FitR` region, the raw destination array has to be read from the file (PDFSave's parser). Through PDFKit, those become "whole page".

## 8. Hover and Force Click

**Observed.**
- **Tracking area:** our `NSTrackingArea` (`.mouseMoved`, `.mouseEnteredAndExited`, `.activeAlways`, `.inVisibleRect`) installs next to PDFView's own two.
- **Synthetic events:**
  - A synthetic `mouseMoved` sent through `NSWindow.sendEvent` reaches the view only while it's the first responder (window → first responder routing), not through the tracking area.
  - A synthetic `mouseEntered` never arrives.
  - Tracking-area delivery is driven by the window server's real cursor. **It can't be verified headlessly; that needs a manual check in M3.**
- **The hover logic itself** is verified, given events:
  - leaving a link before 0.5 s gives no preview,
  - staying past 0.5 s gives exactly one, with the right `LinkTarget`,
  - `areaOfInterest(for:)` reports `.linkArea` over a link.
- **Force Click API:**
  - `PDFView` doesn't override `pressureChangeWithEvent:` or `quickLookWithEvent:`, so a subclass gets them.
  - `pressureConfiguration` can be set (`.primaryDeepClick`).
  - `PDFView` installs an `NSImmediateActionGestureRecognizer`, with the view as its delegate (`immediateActionRecognizerWillPrepare:`). It can be removed. *Inferred, not observed:* in AppKit this recognizer drives Force Click actions such as Look Up and previews.
  - A pressure event can't be synthesised through public API: `NSEvent(cgEvent:)` on a CGEvent retyped to `NSEventTypePressure` crashed the test host. **Physical pressure is unverified.**

**Evidence.** `Q8Hover`: `trackingAreaIsInstalled`, `syntheticEventsThroughTheWindow`, `hoverDelayLogicGivenEvents`, `forceClickAPI`.

**Architecture.** §4.4 hover and Force Click are **confirmed at the API level**. Two additions:
- Remove the immediate-action recognizer, so Force Click goes only to `pressureChange` and never to PDFKit's own handling. We infer that handling may show a link preview, which could fetch a web page against A4. That wasn't observed.
- Add a manual M3 check of real hover and Force Click.

## 9. Thumbnails on a background actor

**Observed.** A `ThumbnailRenderer` actor opens its own `PDFDocument` from the same `Data` and renders with `PDFPage.thumbnail(of:for:)`, rasterising each `NSImage` to a `CGImage`. On a generated 600-page document:
- **One actor:** 600 thumbnails at 120×160 in **0.36 s (0.6 ms per page)**, off the main thread. Meanwhile the main thread rendered 120 pages of its own `PDFDocument` concurrently (0.28 s).
- **Two actors, 300 pages each:** 0.20 s wall (about 1.8× faster).
- **Matching:** background thumbnails match main-thread thumbnails for the same pages; the non-white pixel counts are identical.
- **Thread Sanitizer:** run by hand with `-enableThreadSanitizer YES`, it reported **no data races**. Under TSan the run took 1.04 s.
- **No thread-safety problems** were seen with one `PDFDocument` per actor. A `PDFDocument` was never shared across threads; that wasn't tested, on purpose.

**Evidence.** `Q9Thumbnails`: `backgroundActorRendersWhileMainThreadUsesItsOwnDocument`, `backgroundAndMainThumbnailsMatch`, `twoActorsInParallel`. Plus the manual TSan run.

**Architecture.** §4.6 thumbnails are **confirmed**. Notes:
- Keep the `PDFDocument` inside the actor; it isn't `Sendable`.
- Return `CGImage`s.
- Rendering blocks a cooperative-pool thread, but at about 1 ms per thumbnail that's acceptable. Batch per request, and check for cancellation between pages.

## 10. Search

**Observed.** On a generated 2,400-page document with the needle on every 50th page (48 matches, the first on page 26):
- **Returns immediately:** `beginFindString` returns in about 0.1 ms, and `isFinding` is true.
- **Progressive results:** the first match arrives after **0.05 s** and the end after **4.34–4.40 s**. Half the matches arrived in the first half of the run.
- **Main thread:** every callback arrives on the main thread: `DidBeginFind`, `DidFindMatch`, `DidEndPageFind` (2,400 of them, one per page), `DidEndFind`, and the delegate's `didMatchString:`. The search work itself runs elsewhere. A 5 ms main run-loop timer kept firing, with a **largest gap of 8.5–8.8 ms**.
- **Delegate versus notifications:** if the document delegate implements `didMatchString:`, the `DidFindMatch` notifications aren't posted at all.
- **Synchronous comparison:** `findString(_:withOptions:)` takes **4.2 s** and blocks the caller.
- **Accent folding:** `.diacriticInsensitive` works ("cafe" finds "Café", "NAIVE" finds "naïve"), although the header lists only case-insensitive, literal and backwards. B8's accent folding is available.

**Evidence.** `Q10Search`: `asynchronousFindOn2400Pages(viaDelegate:)` (both variants), `synchronousFindForComparison`, `diacriticInsensitiveOption`.

**Architecture.** §4.6 and B8 are **confirmed**:
- Use `beginFindString` with notifications. That leaves the single `PDFDocument.delegate` slot free, which matters because panes share the document (§7).
- Throttle UI updates: 2,400 per-page notifications arrive on main.
- Searches run per document, not per pane. Running two concurrent searches on one document wasn't tested.

## 11. Pixel checks offscreen

**Observed.**
- **`PDFPage.draw(with:to:)`** into a bitmap `CGContext` works, and **includes annotations**: 373 dark text pixels; 8,980 yellow pixels from a highlight; 10,000 red pixels from a filled square.
- **`PDFView.cacheDisplay(in:to:)` isn't blank:** it captures the page content tiles (about 1,500 dark pixels at 2×).
- **But it doesn't capture annotations**: 0 highlight pixels, 0 square pixels.
- The same is true of `documentView.cacheDisplay` and `CALayer.render(in:)`. PDFKit draws annotations in separate effect layers that these paths don't include.

**Evidence.** `Q11Pixels`: `pageDrawIntoCGContextRendersTextAndAnnotations`, `pdfViewOffscreenCapture`.

**Architecture (§9 testing).**
- Use `PDFPage.draw(with:to:)` for visual checks of page and annotation rendering.
- Use the model, or the effect-layer census as in Q7, for "the view shows it".
- Never use `cacheDisplay` to assert that an annotation is visible.
- Window-server capture would need Screen Recording permission, so it's ruled out.

---

## macOS 27 *(Added 2026-11-01)*

Observed on GitHub's `xcode-27` runner (macOS 27.0.1, 26A434, Xcode 27.1, a virtual machine) against the same suite on `macos-26`. Each test now pins both versions with `#available(macOS 27, *)`, and Q11 pins the machine. What this means for Lectern is in architecture.md §8, "macOS 27".

| # | What macOS 27 does differently |
|---|--------------------------------|
| 1 | `dataRepresentation()` keeps every script and trigger, and the link keeps its JavaScript action. Scripts still never run. |
| 2 | A link's action runs after `mouseDown` returns, not during it. `_addOpenItemsToMenu:onPage:atPagePoint:` is gone; `openRepresentedLink:` and `copyLink:` remain. |
| 3 | A stock `PDFView` handles clicks with gesture recognizers. So clicks sent straight to the hit view edit nothing, while clicks through `NSWindow.sendEvent`, with the app active, edit as before. A subclass that overrides the mouse handlers keeps the mouse-down path. The rewrite no longer adds `/Ff 0`. |
| 4 | `/Rotate` is written only where it isn't 0, and a `PDFPage` subclass's rotation no longer leaks into the file. |
| 5 | Each annotation is written once, without `/Border` or `/DA`, and popups aren't written. In memory, `/T` and `/M` are still filled in. |
| 6 | The rewrite keeps custom keys, page labels, `/OpenAction`, orphan objects, every link action and the form whole, with a `%PDF-1.7` header. It still drops `/ID` and `/Prev`, and the original still isn't a prefix. |
| 7 | A live annotation change reaches every view on the document. |
| 10 | Unchanged in behaviour; the find took about twice as long on the runner. |
| 11 | Unchanged by macOS 27. On the runners' virtual machines, offscreen captures of a `PDFView` are blank on both versions. |

## How the tests drive PDFKit headlessly

These points matter for every future AppKit test in this project (`SpikeHosting.swift`):

- **The window:**
  - The test host app is never active, and activating it would steal focus.
  - So `NSWindow.sendEvent` treats every click as a window-activating first click and drops it. `Synth.click` hit-tests and calls `mouseDown`/`mouseUp` on the hit view, which is what an active window does.
  - `KeyableWindow` reports itself key.
- **Queued mouse events:**
  - `NSEvent.mouseEvent(…)` events that pass through `NSApp.postEvent` come back with the **live cursor position**, not their own.
  - PDFKit's link tracking reads the queued mouse-up, so its result depended on where the developer's mouse was. That made the tests flaky until fixed.
  - The fix has two parts: the queued mouse-up is built from a `CGEvent` with an explicit location (`Synth.cgMouse`), and the host window sits at the primary screen's origin, so screen and window coordinates coincide.
  - The window is fully transparent (`alphaValue = 0`) and click-through (`ignoresMouseEvents`), so it's invisible and can't catch real clicks.
  - No event is ever posted to a system event tap, so there's no Accessibility, Input Monitoring or Screen Recording prompt.
- **On CI** *(Added 2026-11-01)* the test host is the active app, so clicks and keys sent through the window (`Synth.windowClick`, `Synth.windowKey`) arrive there. Tests that need them run only while `NSApp.isActive`; nothing ever activates the host.
- **The `NSWorkspace` tripwire:** every open and launch method of `NSWorkspace` is replaced in the test process with a recorder. Fixture targets are inert anyway: unregistered schemes, `.invalid` hosts, and paths that don't exist.
- **Serialized suites:** all spike suites are nested in one suite marked `.serialized`, with a time limit.
- **Requirement:** because the host window sits on a real screen, these tests need a logged-in GUI session with a display, and a primary screen at least about 900 pt tall (the window is 700×900). This bears on the CI **[verify]** in architecture.md §8, which this spike doesn't settle.

## Not verified

- Real hover and tracking-area delivery, and physical Force Click pressure (§8). This needs a manual check in M3.
- Whether PDFKit's real right-click menu offers "Open Link" over a link. It didn't appear headlessly. The `openRepresentedLink:` override covers it either way.
- Tab inside a focused field with a real keyboard (§3). Moot once clicks are blocked.
- VoiceOver or accessibility activation of form widgets (§3) and of links (§2). The `perform(_:)` choke point should cover links, but that wasn't tested.
- Whether a stale pane *draws* a live annotation through some path other than its effect layers. That can't be checked with pixels offscreen (§7, §11).
- Two concurrent searches on one document. Sharing one `PDFDocument` across threads, deliberately not tried.
- Performance on the baseline M1 with 8 GB (A6). These numbers are from an M3 Pro.
