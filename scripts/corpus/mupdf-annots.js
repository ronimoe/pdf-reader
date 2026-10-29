// Lists annotations as MuPDF sees them. Usage: mutool run mupdf-annots.js <file.pdf>
// Prints JSON: [{page, ref, type, contents, hasAP}], plus widgets with type "Widget".
var doc = Document.openDocument(scriptArgs[0]);
var out = [];
function hasAP(obj) {
  var ap = obj.get("AP");
  return ap ? ap.isDictionary() : false;
}
for (var i = 0; i < doc.countPages(); i++) {
  var page = doc.loadPage(i);
  var annots = page.getAnnotations();
  for (var j = 0; j < annots.length; j++) {
    var a = annots[j];
    var obj = a.getObject();
    out.push({
      page: i,
      ref: obj.isIndirect() ? obj.asIndirect() : null,
      type: a.getType(),
      contents: a.getContents() || "",
      hasAP: hasAP(obj)
    });
  }
  var widgets = page.getWidgets();
  for (var k = 0; k < widgets.length; k++) {
    var w = widgets[k].getObject();
    out.push({ page: i, ref: w.isIndirect() ? w.asIndirect() : null, type: "Widget", contents: "", hasAP: hasAP(w) });
  }
}
print(JSON.stringify(out));
