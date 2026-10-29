// Lists annotations as pdf.js sees them, or renders one page.
//   node pdfjs-annots.mjs <file.pdf> [--password <password>]
//     → JSON {annotations: [{page, ref, subtype, contents, hasAppearance}], warnings: [...]}
//   node pdfjs-annots.mjs <file.pdf> --render <pageIndex> <out.png>
//     → renders the page at 72 dpi with annotations (needs @napi-rs/canvas, an optional
//       dependency of pdfjs-dist) and prints JSON {warnings: [...]}
// pdf.js repairs damaged files quietly ("Indexing all PDF objects"), so its warnings are captured
// and returned for the caller to fail on.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const warnings = [];
const capture = (...args) => warnings.push(args.map(String).join(" "));
const realLog = console.log;
console.log = capture;
console.warn = capture;
console.error = capture;

const { getDocument, VerbosityLevel, AnnotationMode } = await import("pdfjs-dist/legacy/build/pdf.mjs");

const pdfjsRoot = new URL("./node_modules/pdfjs-dist/", import.meta.url);
const args = process.argv.slice(2);
const at = args.indexOf("--password");
const password = at >= 0 ? args.splice(at, 2)[1] : "";
process.argv = [process.argv[0], process.argv[1], ...args];
const data = new Uint8Array(readFileSync(process.argv[2]));
const task = getDocument({
  data,
  password,
  verbosity: VerbosityLevel.WARNINGS,
  isEvalSupported: false,
  stopAtErrors: true,
  standardFontDataUrl: fileURLToPath(new URL("standard_fonts/", pdfjsRoot)),
  cMapUrl: fileURLToPath(new URL("cmaps/", pdfjsRoot)),
  cMapPacked: true,
});
const doc = await task.promise;

if (process.argv[3] === "--render") {
  const page = await doc.getPage(Number(process.argv[4]) + 1);
  const viewport = page.getViewport({ scale: 1 });
  const { canvas, context } = doc.canvasFactory.create(Math.round(viewport.width), Math.round(viewport.height));
  await page.render({ canvas, canvasContext: context, viewport, annotationMode: AnnotationMode.ENABLE }).promise;
  writeFileSync(process.argv[5], canvas.toBuffer("image/png"));
  await task.destroy();
  realLog(JSON.stringify({ warnings }));
} else {
  const annotations = [];
  for (let i = 1; i <= doc.numPages; i++) {
    const page = await doc.getPage(i);
    for (const a of await page.getAnnotations({ intent: "display" })) {
      // ids are "<num>R" or "<num>R<gen>" for indirect annotations.
      const m = /^(\d+)R(\d*)$/.exec(a.id ?? "");
      annotations.push({
        page: i - 1,
        ref: m ? Number(m[1]) : null,
        subtype: a.subtype,
        contents: a.contentsObj?.str ?? "",
        hasAppearance: Boolean(a.hasAppearance),
      });
    }
  }
  await task.destroy();
  realLog(JSON.stringify({ annotations, warnings }));
}
