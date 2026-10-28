# Product Specification — Open-Source PDF Reader for macOS

- **Document version:** 1.0 — Initial Product Requirements
- **Product name:** To be determined
- **Initial platform:** macOS
- **Project model:** Free and open source
- **Status:** Product vision and scope definition

## 1. Product Vision

Create a beautiful, fast, reliable, and distraction-free PDF reader designed specifically for the Mac.

The application should feel like a natural part of macOS, rather than a large document-processing suite.

It should make reading and navigating PDF documents enjoyable, especially for people who regularly work with long books, academic papers, manuals, reports, and technical documents.

**Core vision:** A PDF reader that respects the document, respects the user's attention, and never gets in the way.

The project should remain free, open source, privacy-respecting, and independent of commercial document platforms.

### 1.1 Product Identity

The application is:

- A PDF reader first.
- A carefully designed native-feeling Mac application.
- A personal reading and annotation workspace.
- A tool that works without an account or internet connection.
- An open-source alternative to commercial PDF readers.
- Simple for casual readers, powerful for frequent readers.

The application is not intended to become a comprehensive document creation, conversion, or enterprise management platform.

## 2. Primary Goals

### Goal 1 — Excellent Reading Experience

Reading is the most important function of the entire application.

The application must provide:

- Smooth, responsive scrolling.
- Clear and accurate document rendering.
- Comfortable zooming and navigation.
- Single-page, continuous-scroll, and two-page reading modes.
- An unobstructed reading area.
- Optional distraction-free reading mode.
- Proper display of documents with different page sizes and orientations.

The reader must never sacrifice document readability for decorative interface elements.

**Success condition:** A user can comfortably read a long PDF for hours without struggling with the interface.

### Goal 2 — Effortless Document Navigation

Users should never feel lost inside a document.

Required capabilities:

- Table-of-contents navigation, when available.
- Page thumbnails.
- Page-number navigation.
- Full-document text search.
- Back and forward navigation history.
- Remembering the last reading position.
- Bookmarks.
- Previewing linked document destinations.
- Reading two different parts of a document side by side.

**Signature experience: Never Lose Your Place**

When a user follows a reference, footnote, figure link, or cross-reference, the reader should let them preview the destination without abandoning their current reading position.

This behavior should be a defining feature of the product.

For the initial release, previews need only work with existing PDF internal links. Automatically interpreting references in ordinary unlinked text is not required.

**Success condition:** Users can explore complex documents and always return to the place they were reading.

### Goal 3 — A Thoughtful macOS Experience

The interface should feel familiar to Mac users without directly copying another application.

Design principles:

- Calm, minimal appearance.
- Clear visual hierarchy.
- Generous reading space.
- Familiar macOS window behavior.
- Collapsible sidebars.
- Contextual tools rather than permanently crowded toolbars.
- Consistent keyboard shortcuts.
- Native-feeling interactions and gestures.
- Appropriate light and dark appearances.
- Support for multiple windows and documents.

The interface must be understandable without a tutorial.

**Success condition:** A first-time user can open a PDF and immediately understand how to read, search, and navigate it.

### Goal 4 — Trustworthy Document Handling

The application must accurately display PDFs and protect the original document from accidental damage.

Required behavior:

- Preserve the document's original layout, images, text, and formatting.
- Handle password-protected documents through normal password entry.
- Avoid modifying files during ordinary reading.
- Make saving and editing behavior predictable.
- Avoid silently discarding document contents or annotations.
- Give clear explanations when unsupported document features are encountered.
- Support local files without requiring an online connection.

**Success condition:** Users feel safe opening important documents and saving their annotations.

### Goal 5 — Respect User Freedom

The project must remain usable without dependence on any company or hosted service.

Non-negotiable principles:

- Free and open-source software.
- No account requirement.
- No subscriptions or paid feature unlocks.
- No advertisements.
- No forced cloud integration.
- No mandatory telemetry.
- No AI features.
- No internet dependency for essential functionality.
- No intentional lock-in of annotations or user documents.

**Success condition:** Anyone can download the application, use it offline, and retain control over their documents.

## 3. Target Users

The product is designed for people who want a better PDF reading experience, including:

- **Everyday Mac users** who want to open documents quickly without unnecessary complexity.
- **Students and researchers** who read papers, books, citations, and long reference materials.
- **Developers and technical readers** who use specifications, manuals, documentation, and diagrams.
- **Professionals** who review reports, proposals, and lengthy documents.

These audiences should use the same core interface. The application should not require separate beginner and professional modes.

## 4. User Interface Specification

### 4.1 Main Window

The application should have three primary interface areas.

**Top toolbar**

A compact toolbar containing essential actions such as sidebar visibility, search, reading options, and annotation access.

The document title should remain visible without taking excessive space.

**Left sidebar**

A collapsible sidebar that can display:

- Document outline.
- Page thumbnails.
- Bookmarks.
- Annotation list.

Only one sidebar section needs to be visible at a time.

**Document canvas**

The central reading area.

It should occupy the majority of the available space and visually prioritize the original PDF pages.

No permanently visible advertisements, promotional sections, assistant panels, or unnecessary controls are allowed.

### 4.2 Appearance

The application should support both light and dark interface appearances.

Light mode should feel clean and bright without excessive contrast.

Dark mode should use comfortable, subdued interface surfaces.

**Important boundary:** Changing the application appearance must not automatically alter the original colors of the PDF itself.

A future optional reading filter may be considered, but preserving document fidelity takes precedence.

### 4.3 Empty State

When opened without a document, the application should display a simple, welcoming empty state.

It may offer an Open Document action and recently opened files.

It must not display a marketing dashboard, product advertisements, account creation prompt, or promotional onboarding flow.

### 4.4 Interaction Guidelines

- Important actions should be discoverable.
- Common actions should be accessible through keyboard shortcuts.
- Secondary actions should remain unobtrusive.
- Hover-dependent features should also have accessible alternatives.
- Contextual controls should appear when useful.
- Animations should be subtle and never block interaction.
- The application should preserve user choices when practical.

## 5. Version 1.0 Functional Scope

The following capabilities define the intended first complete public release.

### 5.1 Document Reading

Included:

- Open local PDF files.
- Open multiple documents.
- Use tabs and separate windows.
- Scroll continuously through pages.
- Switch between single-page and two-page layouts.
- Zoom in, zoom out, and fit page or width.
- Rotate the viewing orientation.
- View documents containing selectable text, images, and scanned pages.
- Open password-protected PDFs with valid credentials.
- Print documents.
- Copy selectable text where permitted.
- Display existing PDF links and annotations.

**Boundary:** The reader is responsible for presenting the original PDF accurately, not reconstructing or redesigning its content.

### 5.2 Document Navigation

Included:

- Outline navigation.
- Thumbnail navigation.
- Direct page navigation.
- Back and forward reading history.
- Search with highlighted matches.
- Previous and next search results.
- Document bookmarks.
- Restore the last reading location.
- Preview destinations of supported internal PDF links.
- Open two locations of the same document in a split view.

**Boundary:** Navigation features must not require AI, remote services, or automatic interpretation of unstructured document content.

### 5.3 Basic Annotations

Included:

- Highlight text.
- Underline text.
- Strike through text.
- Add text notes.
- View existing supported annotations.
- Edit and remove annotations created by the user.
- Navigate between annotations.
- Save annotations with the PDF in a portable, standards-compatible form.

**Boundary:** Annotation functionality is for reading and reviewing documents, not unrestricted document editing.

Annotation saving must not unexpectedly flatten, remove, or alter unrelated document content.

If a document cannot safely be saved with modifications, the application must explain the limitation and provide a safe alternative where possible.

### 5.4 Reading Sessions

Included:

- Remember recent documents.
- Remember reading positions.
- Restore the user's preferred reading layout.
- Restore open documents when session restoration is enabled.
- Remember sidebar visibility and zoom preferences when appropriate.

**Boundary:** These conveniences must work locally and must not require creating an online user profile.

### 5.5 macOS Experience

Included:

- Standard Mac window expectations.
- Full-screen usage.
- Multiple windows.
- Keyboard navigation.
- Familiar menu organization.
- Drag-and-drop document opening.
- Standard file opening and saving interactions.
- Dark and light appearance.
- Accessibility support for application controls and readable document content where available.

**Boundary:** macOS is the only required platform for version 1.0.

The product must not compromise the Mac experience to preserve compatibility with other operating systems.

## 6. Explicit Non-Goals

The following features are not part of the product's intended direction, unless its mission is deliberately redefined.

### 6.1 AI and Automation

The application will not include:

- AI chat.
- Document summarization using AI.
- Generative AI assistants.
- AI-based document rewriting.
- AI document analysis.
- AI search requiring model services.

The product's value must come from excellent reading and navigation, not artificial intelligence.

### 6.2 Commercial Platform Features

The application will not include:

- Subscription tiers.
- Advertisements.
- Paid premium features.
- Account registration as a prerequisite.
- Commercial upselling screens.
- Mandatory cloud storage.
- Proprietary feature restrictions.

### 6.3 Enterprise Document Management

The application will not attempt to become:

- A team collaboration platform.
- A document approval system.
- A workflow automation platform.
- A shared document repository.
- An enterprise administration product.
- A document analytics or monitoring service.

### 6.4 Full PDF Editing

The application is not intended to compete with comprehensive PDF authoring software.

The following are outside the initial product scope:

- Editing existing paragraphs inside PDFs.
- Replacing embedded images.
- Redesigning pages.
- Page rearrangement and deletion.
- Merging or splitting PDF files.
- PDF compression and optimization tools.
- Converting between PDF and office formats.
- Creating PDFs from scratch.

These capabilities should not be added merely because competing PDF applications offer them.

## 7. Version 1.0 Exclusions That May Be Revisited

These are different from permanent non-goals. They may be useful in the future, but they must not delay the first complete release.

- Optical character recognition for scanned documents.
- Form filling.
- Creating or verifying digital signatures.
- Freehand drawing and advanced markup.
- Advanced document comparison.
- Multi-document search.
- Custom reading themes that change PDF page appearance.
- Reading progress statistics.
- Automated reference detection when PDF links do not exist.
- macOS-independent versions.
- iPhone and iPad applications.
- Remote document synchronization.

The presence of an item here is not a commitment to implement it later.

Future additions should be evaluated against the core mission.

## 8. Product Boundaries and Decision Rules

These rules guide design decisions and prevent uncontrolled feature expansion.

### Rule 1 — Reading Comes First

If a feature makes the primary reading interface more crowded or harder to understand, it must be redesigned, made optional, or rejected.

### Rule 2 — Do Not Recreate Adobe Acrobat

The application should not pursue feature parity with Adobe Acrobat or any other comprehensive PDF suite.

A missing feature is not automatically a product weakness.

### Rule 3 — Simplicity Is a Feature

Prefer a small number of excellent capabilities over a large number of inconsistent or poorly finished tools.

### Rule 4 — Preserve Document Fidelity

The application must not modify a PDF's visual contents merely to make it conform to an interface preference.

### Rule 5 — User Data Stays Under User Control

Documents, annotations, bookmarks, and reading preferences must remain accessible without a proprietary online service.

### Rule 6 — No Surprise Network Activity

Reading a local PDF must not cause its contents to be uploaded or transmitted.

Any feature that accesses an external destination must have a clear user-facing purpose and appropriate user control.

### Rule 7 — No Silent Data Loss

The application must favor safe, predictable behavior whenever document saving, modification, or compatibility is uncertain.

### Rule 8 — Accessible By Design

Important functions must not depend exclusively on colors, gestures, hover states, or precise pointer movement.

### Rule 9 — macOS First

Decisions for the first release should prioritize a high-quality Mac experience rather than speculative future platforms.

### Rule 10 — Open Source Is a Permanent Commitment

The essential reader must remain available as a complete open-source product.

Community contributions and transparent development should be encouraged without compromising product consistency.

## 9. Performance and Quality Expectations

The application should feel lightweight, dependable, and responsive in everyday use.

### 9.1 Responsiveness

- Opening ordinary PDFs should feel fast.
- Scrolling should remain smooth during normal reading.
- Zooming should not feel unnecessarily delayed.
- Search must provide clear feedback and usable results.
- Large documents should not cause the entire interface to become unresponsive.
- Users should be able to interact with the interface while time-consuming document operations are underway.

Performance should be evaluated using representative documents, including text-heavy books, image-heavy reports, scanned documents, and long technical manuals.

Exact numeric performance thresholds should be established through testing on supported Mac hardware before release.

### 9.2 Stability

- Ordinary reading should never change the original file.
- A failed document operation must not crash the entire application.
- Unexpectedly closing the application should not corrupt source documents.
- Unsupported PDFs should produce understandable feedback.
- Password prompts and error messages should be clear.
- Saving should protect the user's work.

### 9.3 Accessibility

- Application controls must support keyboard operation.
- Controls should have clear accessible names.
- Text selection and navigation should work with assistive technologies where document content permits.
- Appearance should maintain usable contrast.
- Motion preferences should be respected.
- Scanned PDFs without accessible text should not be represented as fully text-accessible.

## 10. Primary User Journeys

### Journey A — Opening and Reading

1. User opens a PDF from Finder.
2. The document appears immediately in a clean reading window.
3. The user scrolls, zooms, and reads.
4. The application remembers their reading position.
5. On reopening the file, the user can resume where they left off.

There should be no mandatory onboarding or setup process.

### Journey B — Following a Reference

1. User reads a document containing an internal PDF reference.
2. User activates the reference preview action.
3. The destination appears without replacing the current reading position.
4. User may dismiss the preview or open the destination in a separate reading pane.
5. User returns to the original text effortlessly.

This should demonstrate the product's distinctive navigation experience.

### Journey C — Studying and Annotating

1. User selects a sentence.
2. A small contextual annotation control appears.
3. User highlights the text or adds a note.
4. User continues reading without entering a complicated editing mode.
5. User saves their work.
6. Supported annotations remain available when the document is opened in another compatible PDF reader.

### Journey D — Reading a Long Document

1. User opens a long document.
2. User navigates with the table of contents.
3. User searches for a phrase.
4. User examines several sections.
5. Navigation history makes it easy to return to earlier locations.
6. User closes the document and resumes later.

No special project setup or document import process should be required.

## 11. Release Acceptance Criteria

Version 1.0 is considered ready when all of the following are true.

**Core functionality**

- Supported ordinary PDF files open and display reliably.
- Essential reading modes work correctly.
- Navigation and search are dependable.
- The reference preview feature works for supported internal links.
- Basic annotations can be created, modified, and saved safely.
- Reading position restoration functions reliably.

**Experience**

- First-time users can accomplish basic reading tasks without instructions.
- The interface remains uncluttered.
- Common actions are discoverable.
- Keyboard accessibility works for essential controls.
- Light and dark appearances are visually consistent.

**Reliability**

- Representative documents have been tested.
- Supported annotation content survives saving and reopening.
- Original document content is not silently corrupted or discarded.
- Invalid or unsupported PDFs are handled safely.
- No known release-blocking crashes remain in normal reading workflows.

**Project principles**

- The application is publicly available as open-source software.
- Core use does not require registration or online access.
- There are no ads, subscriptions, or AI features.
- Installation and basic usage are documented.
- Known limitations are clearly communicated.

## 12. Future Development Philosophy

Future development should deepen the reading experience rather than expand the application into an unrelated collection of tools.

Possible areas of improvement include more advanced reading layouts, stronger annotation workflows, better handling of difficult documents, accessibility enhancements, and additional navigation conveniences.

Every proposed feature should answer three questions:

1. Does it meaningfully improve reading, navigation, or annotation?
2. Can it be introduced without making the application unnecessarily complex?
3. Does it preserve the project's commitments to privacy, freedom, and document reliability?

Features that fail these tests should normally be rejected.

## 13. Out of Scope for This Specification

This specification intentionally does not determine:

- Programming language.
- Framework or user interface toolkit.
- PDF rendering engine.
- Software architecture.
- Internal data structures.
- Storage implementation.
- Third-party dependencies.
- Build or distribution tooling.
- Specific open-source license.
- Development schedule or staffing.

These decisions should be addressed separately after the product requirements have been agreed upon.

## 14. Product Definition

**We are building:** A free, open-source PDF reader for macOS that makes reading, navigating, and annotating documents feel simple, fast, and natural.

**We are not building:** An Adobe Acrobat clone, a PDF creation suite, an AI document assistant, a cloud document platform, or a commercial software ecosystem.

**Our defining advantage:** A focused reading experience where users can explore complex documents without losing their place.

**Our standard for success:** Users should choose this application not because it has the most features, but because it is the PDF reader they genuinely prefer to use every day.

**Final product principle:** Open a document. Focus on what matters. Never fight the reader.
