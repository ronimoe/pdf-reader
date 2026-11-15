import CoreGraphics
import Foundation
import Testing
@testable import ReaderCore

/// Citation previews' pure parts: reading a reference-list entry's printed text, and finding the
/// entry's lines on a page. The entries are as PDFKit extracts them from real papers and from
/// LaTeX's common bibliography styles.
@Suite struct CitedWorkParsingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let style: String
        let entry: String
        let authors: String?
        let title: String?
        let series: String?
        let year: Int?
        var url: String? = nil
        var testDescription: String { style }
    }

    static let cases: [Case] = [
        Case(
            style: "natbib (names first, title as a sentence)",
            entry: "Will Hamilton, Zhitao Ying, and Jure Leskovec. Inductive representation learning on large graphs. Advances in Neural Information Processing Systems, 30, 2017.",
            authors: "Will Hamilton, Zhitao Ying, and Jure Leskovec", title: "Inductive representation learning on large graphs",
            series: "Advances in Neural Information Processing Systems", year: 2017
        ),
        Case(
            style: "natbib with a URL",
            entry: "Diederik P. Kingma and Jimmy Ba. Adam: A method for stochastic optimization. In International Conference on Learning Representations, 2015. URL https://arxiv.org/abs/1412.6980.",
            authors: "Diederik P. Kingma and Jimmy Ba", title: "Adam: A method for stochastic optimization",
            series: "International Conference on Learning Representations", year: 2015, url: "https://arxiv.org/abs/1412.6980"
        ),
        Case(
            style: "IEEE (title in quotes, arXiv)",
            entry: "[12] G. Ceruti, L. Einkemmer, J. Kusch, and C. Lubich, “A robust second-order low-rank bug integrator based on the midpoint rule,” arXiv preprint arXiv:2402.08607, 2024.",
            authors: "G. Ceruti, L. Einkemmer, J. Kusch, and C. Lubich", title: "A robust second-order low-rank bug integrator based on the midpoint rule",
            series: "arXiv preprint", year: 2024, url: "https://arxiv.org/abs/2402.08607"
        ),
        Case(
            style: "IEEE, quotes inside the title",
            entry: "[19] M. T. Ribeiro, S. Singh, and C. Guestrin, ““Why should I trust you?”: Explaining the predictions of any classifier,” in Proceedings of the 22nd ACM SIGKDD International Conference on Knowledge Discovery and Data Mining, 2016, pp. 1135–1144.",
            authors: "M. T. Ribeiro, S. Singh, and C. Guestrin", title: "“Why should I trust you?”: Explaining the predictions of any classifier",
            series: "Proceedings of the 22nd ACM SIGKDD International Conference on Knowledge Discovery and Data Mining", year: 2016
        ),
        Case(
            style: "IEEE book: edition, DOI",
            entry: "[1] J. R. Howell, M. P. Menguc, and R. Siegel, Thermal Radiation Heat Transfer (5th ed.) CRC Press, 2010. doi: https://doi.org/10.1201/9781439894552.",
            authors: "J. R. Howell, M. P. Menguc, and R. Siegel", title: "Thermal Radiation Heat Transfer",
            series: "CRC Press", year: 2010, url: "https://doi.org/10.1201/9781439894552"
        ),
        Case(
            style: "IEEE, TeX accents and a URL run into the year",
            entry: "[16] M. G. L´opez and J. de la Cruz, “Particles and accents,” https://example.org/particles,2022.",
            authors: "M. G. López and J. de la Cruz", title: "Particles and accents",
            series: nil, year: 2022, url: "https://example.org/particles"
        ),
        Case(
            style: "APA-like (surname first, year in brackets)",
            entry: "LeCun, Y., Bengio, Y., and Hinton, G. (2015). Deep learning. Nature, 521(7553):436–444.",
            authors: "LeCun, Y., Bengio, Y., and Hinton, G.", title: "Deep learning", series: "Nature", year: 2015
        ),
        Case(
            style: "Chicago (only the first name turned round)",
            entry: "Kingma, D. P. and J. Ba (2015). Adam: A method for stochastic optimization. In International Conference on Learning Representations.",
            authors: "Kingma, D. P. and J. Ba", title: "Adam: A method for stochastic optimization",
            series: "International Conference on Learning Representations", year: 2015
        ),
        Case(
            style: "Springer LNCS (colon after the names)",
            entry: "8. Kingma, D.P., Ba, J.: Adam: A method for stochastic optimization. In: International Conference on Learning Representations (2015), https://arxiv.org/abs/1412.6980",
            authors: "Kingma, D.P., Ba, J.", title: "Adam: A method for stochastic optimization",
            series: "International Conference on Learning Representations", year: 2015, url: "https://arxiv.org/abs/1412.6980"
        ),
        Case(
            style: "Springer LNCS, a corporate author",
            entry: "15. OpenAI: GPT-4 technical report. https://openai.com/research/gpt-4 (2023)",
            authors: "OpenAI", title: "GPT-4 technical report", series: nil, year: 2023, url: "https://openai.com/research/gpt-4"
        ),
        Case(
            style: "Springer LNCS, a URL with a space after its scheme",
            entry: "5. Goodfellow, I., Bengio, Y., Courville, A.: Deep Learning. MIT Press (2016), http: //www.deeplearningbook.org",
            authors: "Goodfellow, I., Bengio, Y., Courville, A.", title: "Deep Learning", series: "MIT Press", year: 2016,
            url: "http://www.deeplearningbook.org"
        ),
        Case(
            style: "Nature book (publisher and year in brackets)",
            entry: "5. Goodfellow, I., Bengio, Y. & Courville, A. Deep Learning (MIT Press, 2016). URL http://www.deeplearningbook.org.",
            authors: "Goodfellow, I., Bengio, Y. & Courville, A.", title: "Deep Learning", series: "MIT Press", year: 2016,
            url: "http://www.deeplearningbook.org"
        ),
        Case(
            style: "Nature journal, et al.",
            entry: "Silver, D. et al. Mastering the game of Go with deep neural networks and tree search. Nature 529, 484–489 (2016).",
            authors: "Silver, D. et al.", title: "Mastering the game of Go with deep neural networks and tree search", series: "Nature", year: 2016
        ),
        Case(
            style: "Vancouver",
            entry: "20. López MG, de la Cruz J. Particles and Accents in Author Lists. Journal of Documentation. 2022;78(4):801-20.",
            authors: "López MG, de la Cruz J", title: "Particles and Accents in Author Lists", series: "Journal of Documentation", year: 2022
        ),
        Case(
            style: "Vancouver, one author",
            entry: "Lovelace A. Notes on the Analytical Engine. University of London; 1843.",
            authors: "Lovelace A", title: "Notes on the Analytical Engine", series: "University of London", year: 1843
        ),
        Case(
            style: "ACM (year after the names)",
            entry: "Ashish Vaswani, Noam Shazeer, and Illia Polosukhin. 2017. Attention is all you need. In Advances in Neural Information Processing Systems. 5998–6008.",
            authors: "Ashish Vaswani, Noam Shazeer, and Illia Polosukhin", title: "Attention is all you need",
            series: "Advances in Neural Information Processing Systems", year: 2017
        ),
        Case(
            style: "a volume in a series",
            entry: "Maxim Raginsky and Igal Sason. Concentration of measure inequalities in information theory, communications and coding, volume 10 of Foundations and Trends in Communications and Information Theory. Now Publishers, 2013.",
            authors: "Maxim Raginsky and Igal Sason", title: "Concentration of measure inequalities in information theory, communications and coding",
            series: "Foundations and Trends in Communications and Information Theory", year: 2013
        ),
        Case(
            style: "a chapter with its pages",
            entry: "Peter L. Bartlett and John Shawe-Taylor. Generalization Performance of Support Vector Machines and Other Pattern Classifiers, pp. 43–54. MIT Press, 1999.",
            authors: "Peter L. Bartlett and John Shawe-Taylor", title: "Generalization Performance of Support Vector Machines and Other Pattern Classifiers",
            series: "MIT Press", year: 1999
        ),
    ]

    @Test(arguments: cases)
    func readsTheParts(of reference: Case) {
        let work = CitedWork(parsing: reference.entry)
        #expect(work.authors == reference.authors)
        #expect(work.title == reference.title)
        #expect(work.series == reference.series)
        #expect(work.year == reference.year)
        #expect(work.url?.absoluteString == reference.url)
        #expect(work.looksLikeReference)
    }

    @Test func theLabelIsNotPartOfTheReference() {
        #expect(CitedWork(parsing: "[12]  A. Smith, “Title,” 2020.").reference == "A. Smith, “Title,” 2020.")
        #expect(CitedWork(parsing: "12. Smith, A.: Title. Journal (2020)").reference == "Smith, A.: Title. Journal (2020)")
        #expect(CitedWork(parsing: "[Smi20] A. Smith. Title. 2020.").reference == "A. Smith. Title. 2020.")
    }

    @Test func aDOIBecomesItsAddressEvenWithSpacesInIt() {
        let work = CitedWork(parsing: "[16] X. Author, “Some title,” Journal of Things, vol. 2, 2019. doi: 10 . 5445 / IR / 1000154134.")
        #expect(work.url?.absoluteString == "https://doi.org/10.5445/IR/1000154134")
        #expect(work.series == "Journal of Things")
        #expect(work.year == 2019)
    }

    @Test func aPrintedURLComesBeforeTheDOI() {
        let work = CitedWork(parsing: "A. Smith. A title. Journal, 2020. doi: 10.1000/xyz123. URL https://example.org/paper.")
        #expect(work.url?.absoluteString == "https://example.org/paper")
    }

    @Test func proseIsNotAReference() {
        #expect(!CitedWork(parsing: "In 2020 we ran more experiments. Smith et al. reported similar findings.").looksLikeReference)
        #expect(!CitedWork(parsing: "B.1 Accuracy Comparisons with Additional Baselines").looksLikeReference)
        #expect(!CitedWork(parsing: "").looksLikeReference)
    }
}

@Suite struct ReferenceListTests {
    @Test(arguments: ["References", "REFERENCES", "R EFERENCES", "7 References", "VII. REFERENCES", "Bibliography", "Références", "Literaturverzeichnis", "Works Cited"])
    func headings(_ text: String) {
        #expect(ReferenceList.isHeading(text))
    }

    @Test(arguments: ["References to prior work", "see the references", "Reference manual", "Related Work", "A Proofs"])
    func notHeadings(_ text: String) {
        #expect(!ReferenceList.isHeading(text))
    }

    @Test func aPageMentioningAHeadingWordIsWorthMeasuring() {
        #expect(ReferenceList.mightHaveHeading("…\nREFERENCES\n[1] A. Smith"))
        #expect(ReferenceList.mightHaveHeading("R EFERENCES"))
        #expect(!ReferenceList.mightHaveHeading("Introduction\nWe study graphs."))
    }

    @Test(arguments: ["12", "[3, 4]", "Smith et al., 2020", "Lineberger et al.", "Kipf & Welling", "2021"])
    func couldBeCitations(_ text: String) {
        #expect(ReferenceList.couldBeCitation(linkText: text))
    }

    @Test(arguments: ["Figure 3", "Fig. 2", "Table 1", "Section 2.1", "Sec. 4", "B.1", "C", "(4)", "Eq. (3)", "Appendix A", "Theorem 2", "Lemma 5", "2.1", "Algorithm 1"])
    func crossReferences(_ text: String) {
        #expect(!ReferenceList.couldBeCitation(linkText: text))
    }

    @Test func linesJoinBackIntoOne() {
        #expect(ReferenceList.joined(["graph neural networks inspired by classical iterative algo-", "rithms. In ICML."]) == "graph neural networks inspired by classical iterative algorithms. In ICML.")
        #expect(ReferenceList.joined(["Hu et al. OGB-", "LSC: a challenge."]) == "Hu et al. OGB-LSC: a challenge.")
        #expect(ReferenceList.joined(["URL https://example.org/some/", "path/paper.pdf."]) == "URL https://example.org/some/path/paper.pdf.")
        #expect(ReferenceList.joined(["URL https://doi.org/10.", "14778/3641204.3641215."]) == "URL https://doi.org/10.14778/3641204.3641215.")
        #expect(ReferenceList.joined(["URL https://example.org/paper.pdf.", "(2023)"]) == "URL https://example.org/paper.pdf. (2023)")
        #expect(ReferenceList.joined(["A title.", "  Journal, 2020."]) == "A title. Journal, 2020.")
    }
}

/// Finding an entry from where a citation link's destination is, on synthetic page lines laid out
/// as LaTeX sets them (y up, as in page space).
@Suite struct ReferenceEntryTests {
    static func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 220, height: CGFloat = 9) -> TextLine {
        TextLine(text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func aHangingIndentEndsAtTheNextEntry() {
        let lines = [
            Self.line("2020.", x: 412, y: 615, width: 20),
            Self.line("Will Hamilton, Zhitao Ying, and Jure Leskovec. Inductive", x: 108, y: 596, width: 396),
            Self.line("representation learning on large graphs.", x: 118, y: 585, width: 386),
            Self.line("Advances in Neural Information Processing Systems, 30, 2017.", x: 118, y: 574, width: 300),
            Self.line("Weihua Hu, Matthias Fey, and Jure Leskovec. Open graph", x: 108, y: 555, width: 396),
            Self.line("benchmark. 2020.", x: 118, y: 544, width: 100),
        ]
        // The destination is a little above the entry and to its left.
        let entry = ReferenceList.entry(at: CGPoint(x: 83, y: 609), in: lines)
        #expect(entry == "Will Hamilton, Zhitao Ying, and Jure Leskovec. Inductive representation learning on large graphs. Advances in Neural Information Processing Systems, 30, 2017.")
    }

    @Test func labelsSetApartJoinTheirTextAndALaterLineMayStartWithAYear() {
        let lines = [
            Self.line("[9]", x: 96.4, y: 700, width: 10),
            Self.line("A. Author and B. Author, “Title of it,” in Proc. Conf.,", x: 117, y: 700, width: 380),
            Self.line("2015. More text.", x: 117, y: 689, width: 100),
            Self.line("[10]", x: 91.8, y: 674, width: 14),
            Self.line("C. Next, “Other,” 2016.", x: 117, y: 674, width: 200),
        ]
        let entry = ReferenceList.entry(at: CGPoint(x: 91.8, y: 712), in: lines)
        #expect(entry == "[9] A. Author and B. Author, “Title of it,” in Proc. Conf., 2015. More text.")
        #expect(ReferenceList.firstRow(below: CGPoint(x: 91.8, y: 712), in: lines)?.bounds.minX == 96.4)
    }

    @Test func aListWithoutIndentsIsSplitBySpace() {
        let lines = [
            Self.line("Smith, J. (2020). A title that", x: 72, y: 500),
            Self.line("goes on. Journal, 1, 2.", x: 72, y: 489),
            Self.line("Jones, K. (2019). Other. Journal.", x: 72, y: 472),
        ]
        #expect(ReferenceList.entry(at: CGPoint(x: 72, y: 512), in: lines) == "Smith, J. (2020). A title that goes on. Journal, 1, 2.")
    }

    @Test func piecesOfALineSplitAtAWideSpaceAreJoinedInOrder() {
        let lines = [
            Self.line("Long", x: 300, y: 500, width: 25),
            Self.line("Sepp Hochreiter and Jürgen Schmidhuber.", x: 108, y: 500, width: 180),
            Self.line("short-term memory. Neural Computation, 1997.", x: 118, y: 489, width: 220),
        ]
        #expect(ReferenceList.entry(at: CGPoint(x: 83, y: 513), in: lines) == "Sepp Hochreiter and Jürgen Schmidhuber. Long short-term memory. Neural Computation, 1997.")
    }

    @Test func anEntryGoesOnAtTheTopOfTheNextColumn() {
        let lines = [
            Self.line("[4] Kaiming He, Xiangyu Zhang, and", x: 77, y: 141, width: 223),
            Self.line("Jian Sun. Deep residual learning", x: 92.5, y: 129, width: 208),
            Self.line("1", x: 303, y: 87, width: 5),
            Self.line("on Computer Vision, 2016.", x: 331, y: 700, width: 200),
            Self.line("[5] Ian Goodfellow. Deep Learning.", x: 315.6, y: 680, width: 223),
            Self.line("MIT Press, 2016.", x: 331, y: 668, width: 100),
            Self.line("[6] L. van der Maaten. t-SNE. 2008.", x: 315.6, y: 650, width: 223),
        ]
        #expect(ReferenceList.entry(at: CGPoint(x: 77, y: 155), in: lines) == "[4] Kaiming He, Xiangyu Zhang, and Jian Sun. Deep residual learning on Computer Vision, 2016.")
        // An entry that ends with its column doesn't take the next column's first entry.
        #expect(ReferenceList.entry(at: CGPoint(x: 315.6, y: 694), in: lines) == "[5] Ian Goodfellow. Deep Learning. MIT Press, 2016.")
    }

    @Test func anEntryGoesOnAtTheTopOfTheNextPagePastThePageNumberAndRunningHead() {
        let lines = [
            Self.line("[11] Earlier entry. 2010.", x: 310.6, y: 160, width: 228),
            Self.line("[12] Tomas Mikolov, Ilya Sutskever, Kai Chen,", x: 310.6, y: 129, width: 228),
            Self.line("Greg S. Corrado, and Jeff Dean. Distributed", x: 331, y: 117, width: 208),
            Self.line("1", x: 303, y: 87, width: 5),
        ]
        let nextPage = [
            Self.line("Preprint under review", x: 250, y: 760, width: 110),
            Self.line("representations of words and phrases. 2013.", x: 92.5, y: 740, width: 208),
            Self.line("[13] Next entry. 2014.", x: 77, y: 720, width: 223),
            Self.line("[14] Another entry. 2015.", x: 77, y: 700, width: 223),
        ]
        let entry = ReferenceList.entry(at: CGPoint(x: 310.6, y: 143), in: lines, nextPage: nextPage)
        #expect(entry == "[12] Tomas Mikolov, Ilya Sutskever, Kai Chen, Greg S. Corrado, and Jeff Dean. Distributed representations of words and phrases. 2013.")
    }

    @Test func aCentredHeadingAfterTheLastEntryIsNotPartOfIt() {
        let lines = [
            Self.line("[20] M. G. López and J. de la Cruz, “Particles and accents", x: 312, y: 611, width: 251),
            Self.line("in author lists,” Journal of Documentation, 2022.", x: 330, y: 602, width: 203),
            Self.line("APPENDIX", x: 405, y: 585, width: 60),
            Self.line("In 2020 we ran more experiments.", x: 312, y: 570, width: 251),
        ]
        #expect(ReferenceList.entry(at: CGPoint(x: 312, y: 620), in: lines) == "[20] M. G. López and J. de la Cruz, “Particles and accents in author lists,” Journal of Documentation, 2022.")
    }

    @Test func nothingStartsNearTheDestination() {
        let lines = [Self.line("Figure 1: A figure.", x: 145, y: 391, width: 82)]
        // A centred figure's destination, with only its caption to the left below it.
        #expect(ReferenceList.entry(at: CGPoint(x: 189, y: 405), in: lines) == nil)
        #expect(ReferenceList.entry(at: CGPoint(x: 72, y: 900), in: lines) == nil)
        #expect(ReferenceList.entry(at: CGPoint(x: 72, y: 500), in: []) == nil)
    }
}
