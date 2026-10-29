// Adds annotations with MuPDF so the corpus has annotations written by another tool.
// Usage: mutool run mupdf-annotate.js <mode> <in.pdf> <out.pdf>
//   mode "third-party": Square + Text + Highlight on page 1, full (non-incremental) save.
//   mode "incremental": one Text note on page 1, saved as an incremental update.
// MuPDF's annotation API uses top-left origin coordinates (y grows downward).
var mode = scriptArgs[0];
var input = scriptArgs[1];
var output = scriptArgs[2];

var doc = Document.openDocument(input);
var page = doc.loadPage(0);

function note(rect, contents) {
  var a = page.createAnnotation("Text");
  a.setRect(rect);
  a.setContents(contents);
  a.setAuthor("MuPDF Tester");
  a.setColor([1, 0.8, 0]);
  a.update();
  return a;
}

if (mode === "third-party") {
  var sq = page.createAnnotation("Square");
  sq.setRect([300, 420, 520, 500]);
  sq.setContents("Square from MuPDF");
  sq.setAuthor("MuPDF Tester");
  sq.setColor([1, 0, 0]);
  sq.update();
  note([540, 60, 560, 80], "Sticky note from MuPDF");
  var hl = page.createAnnotation("Highlight");
  hl.setQuadPoints([[72, 560, 300, 560, 72, 576, 300, 576]]);
  hl.setContents("Highlight from MuPDF");
  hl.setAuthor("MuPDF Tester");
  hl.setColor([0, 1, 0]);
  hl.update();
  doc.save(output, "garbage=compact");
} else if (mode === "incremental") {
  note([540, 100, 560, 120], "Note added in an earlier incremental update");
  doc.save(output, "incremental");
} else {
  throw new Error("unknown mode " + mode);
}
