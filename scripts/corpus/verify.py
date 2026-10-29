#!/usr/bin/env python3
"""Checks the incremental writer's outputs against the pass criteria of architecture §3.2.

Input is the manifest.json written by the PDFSave corpus tests (Packages/LecternKit, `swift test`).
Each case gets one status per check:

  pass[: detail]   criterion met
  fail: reason     criterion not met
  skip: reason     a tool is missing (never reported as pass)
  n/a: reason      criterion doesn't apply to this file
  info: detail     measured, not a pass/fail criterion (rendering without /AP)

Readers that quietly repair damaged files are watched: qpdf warnings, MuPDF and Poppler
stderr, and pdf.js warnings all count as failures, unless the same message (with the file path
removed) also appears for the unmodified input. Real-world files often trigger warnings before
anything is saved (broken linearization hints, font quirks, structure trees); only messages the
save introduced count.
"""
from __future__ import annotations

import argparse
import json
import logging
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKS = ["prefix", "qpdf", "objects", "fields", "signature", "mupdf", "poppler", "pdfjs", "refused"]
TITLES = {
    "prefix": "1 Bytes prefix",
    "qpdf": "2 qpdf --check",
    "objects": "2b Untouched objects",
    "fields": "4 Form fields",
    "signature": "5 Signature",
    "mupdf": "6 MuPDF",
    "poppler": "6 Poppler",
    "pdfjs": "6 pdf.js",
    "refused": "7 Encrypted refused",
}


def ref_key(s: str) -> tuple[int, int]:
    n, g = s.split()
    return int(n), int(g)


def have_python_libs() -> str | None:
    try:
        import pikepdf  # noqa: F401
        import PIL  # noqa: F401
        return None
    except ImportError as e:
        return f"skip: Python library missing ({e.name}); run scripts/corpus/bootstrap"


# ---------------------------------------------------------------------------- checks


def check_prefix(case):
    original = Path(case["input"]).read_bytes()
    output = Path(case["output"]).read_bytes()
    if output[: len(original)] != original:
        return "fail: original bytes are not a prefix of the output"
    return f"pass: +{len(output) - len(original)} bytes"


def messages(text: str, *paths: str) -> list[str]:
    """Non-empty output lines with the file paths removed, so input and output can be compared."""
    out = []
    for line in text.splitlines():
        for p in paths:
            line = line.replace(p, "<file>")
        if line.strip():
            out.append(line.strip())
    return out


def new_messages(before: list[str], after: list[str]) -> list[str]:
    """Messages for the output that the input didn't already produce.

    Real-world files often make readers complain before we touch them (broken linearization
    hints, odd fonts, structure trees). Only complaints the save introduced count."""
    seen = set(before)
    return [m for m in after if m not in seen]


def check_qpdf(case):
    if not shutil.which("qpdf"):
        return "skip: qpdf not installed"

    def run_check(path):
        r = subprocess.run(["qpdf", "--check", path], capture_output=True, text=True)
        lines = [m for m in messages(r.stdout + r.stderr, path) if "WARNING" in m or "ERROR" in m]
        return r.returncode, lines

    code_out, out = run_check(case["output"])
    if code_out == 0 and not out:
        return "pass"
    code_in, before = run_check(case["input"])
    added = new_messages(before, out)
    # Exit 3 means "warnings"; it passes only when every warning was already there in the input.
    if code_out not in (0, 3) or added:
        return f"fail: exit {code_out}: {'; '.join((added or out)[:3])}"
    return f"pass: {len(out)} warning(s), all already in the input"


def u(obj, resolved=False) -> str:
    """unparse() that also accepts the Python scalars pikepdf returns for numbers and booleans."""
    import pikepdf

    if isinstance(obj, pikepdf.Object):
        return bytes(obj.unparse(resolved=resolved)).decode("latin-1")
    return f"{type(obj).__name__}:{obj!r}"


def same_object(a, b) -> bool:
    import pikepdf

    # pikepdf returns scalar objects (integers, booleans, reals) as Python values.
    if not isinstance(a, pikepdf.Object) or not isinstance(b, pikepdf.Object):
        return type(a) is type(b) and a == b
    if isinstance(a, pikepdf.Stream) != isinstance(b, pikepdf.Stream):
        return False
    if isinstance(a, pikepdf.Stream):
        return a.stream_dict.unparse() == b.stream_dict.unparse() and a.read_raw_bytes() == b.read_raw_bytes()
    # resolved=True: an indirect object would otherwise unparse as just "n g R".
    return a.unparse(resolved=True) == b.unparse(resolved=True)


def xref_objects(path) -> set[tuple[int, int]]:
    """Every in-use (number, generation) in the newest revision, from `qpdf --show-xref`."""
    r = subprocess.run(["qpdf", "--show-xref", path], capture_output=True, text=True, check=True)
    result = set()
    for line in r.stdout.splitlines():
        head, _, kind = line.partition(":")
        if "/" in head and "free" not in kind:
            n, g = head.split("/")
            result.add((int(n), int(g)))
    return result


def check_objects(case):
    missing = have_python_libs()
    if missing:
        return missing
    if not shutil.which("qpdf"):
        return "skip: qpdf not installed"
    import pikepdf

    rewritten = {ref_key(r) for r in case["rewritten"]}
    written = {ref_key(r) for r in case["written"]}
    src_ogs = xref_objects(case["input"])
    dst_ogs = xref_objects(case["output"])
    with pikepdf.open(case["input"], inherit_page_attributes=False) as src, pikepdf.open(case["output"], inherit_page_attributes=False) as dst:
        changed = []
        for og in sorted(src_ogs - rewritten):
            if og not in dst_ogs or not same_object(src.get_object(og), dst.get_object(og)):
                changed.append(og)
        unexpected = sorted(dst_ogs - src_ogs - written)
        # Rewritten pages may differ only in /Annots.
        page_diffs = []
        for og in rewritten:
            a = src.get_object(og)
            if isinstance(a, pikepdf.Dictionary) and a.get("/Type") == pikepdf.Name.Page:
                b = dst.get_object(og)
                ka = {k: u(a[k]) for k in a.keys() if k != "/Annots"}
                kb = {k: u(b[k]) for k in b.keys() if k != "/Annots"}
                if ka != kb:
                    page_diffs.append(og)
        problems = []
        if changed:
            problems.append(f"objects changed without being declared: {changed[:5]}")
        if unexpected:
            problems.append(f"undeclared new objects: {unexpected[:5]}")
        if page_diffs:
            problems.append(f"rewritten pages changed beyond /Annots: {page_diffs}")
        if problems:
            return "fail: " + "; ".join(problems)
        return f"pass: {len(src_ogs) - len(rewritten & src_ogs)} of {len(src_ogs)} original objects identical"


def form_fields(pdf):
    import pikepdf

    acro = pdf.Root.get("/AcroForm")
    if acro is None:
        return None, {}
    fields = {}

    def walk(field, prefix):
        name = prefix
        if "/T" in field:
            t = bytes(field.T).decode("latin-1")
            name = f"{prefix}.{t}" if prefix else t
        rec = {}
        for key in ("/FT", "/V", "/DV", "/Ff", "/AS"):
            if key in field:
                rec[key] = u(field[key], resolved=True)
        widgets = []
        for kid in field.get("/Kids", []):
            if "/T" in kid:
                walk(kid, name)
            else:
                widgets.append(u(kid.get("/AS", pikepdf.Name("/None"))))
        rec["widgets"] = widgets
        fields.setdefault(name, []).append(rec)

    for f in acro.get("/Fields", []):
        walk(f, "")
    return u(acro, resolved=True), fields


def check_fields(case):
    missing = have_python_libs()
    if missing:
        return missing
    import pikepdf

    with pikepdf.open(case["input"], inherit_page_attributes=False) as src, pikepdf.open(case["output"], inherit_page_attributes=False) as dst:
        acro_a, fa = form_fields(src)
        acro_b, fb = form_fields(dst)
        if acro_a is None:
            return "n/a: no AcroForm" if acro_b is None else "fail: AcroForm appeared"
        if acro_a != acro_b:
            return "fail: /AcroForm dictionary changed"
        if fa != fb:
            diff = [k for k in set(fa) | set(fb) if fa.get(k) != fb.get(k)]
            return f"fail: field values differ: {diff[:5]}"
        return f"pass: {len(fa)} fields identical (/V /DV /AS /Ff)"


def check_signature(case):
    try:
        from pyhanko.keys import load_cert_from_pemder
        from pyhanko.pdf_utils.reader import PdfFileReader
        from pyhanko.sign.validation import validate_pdf_signature
        from pyhanko_certvalidator import ValidationContext
    except ImportError:
        return "skip: pyHanko not installed; run scripts/corpus/bootstrap"
    with open(case["output"], "rb") as f:
        reader = PdfFileReader(f)
        sigs = reader.embedded_signatures
        if not sigs:
            return "n/a: unsigned"
        cert = Path(case["input"]).with_suffix(".cert.pem")
        # pyHanko logs a traceback when its diff analysis meets annotation changes it has no rule
        # for; the outcome is reported through modification_level below instead.
        logging.getLogger("pyhanko").setLevel(logging.CRITICAL)
        if not cert.exists():
            # A real-world signed file (GovInfo's): its certificate chain isn't ours to trust and
            # its signing certificate has since expired, so trust isn't evaluated. The criterion is
            # that the signature is untouched: intact, cryptographically valid, and covering its
            # whole revision.
            if "/realworld/" not in case["input"]:
                return f"fail: signed but trust root {cert.name} missing"
            vc = ValidationContext(allow_fetching=False)
            details = []
            ok = True
            for sig in sigs:
                st = validate_pdf_signature(sig, vc)
                details.append(f"{sig.field_name}: intact={st.intact} valid={st.valid} coverage={st.coverage.name} "
                               f"modification={st.modification_level.name} (trust not evaluated)")
                ok &= bool(st.intact and st.valid and st.coverage.name == "ENTIRE_REVISION")
            return ("pass: " if ok else "fail: ") + "; ".join(details)
        vc = ValidationContext(trust_roots=[load_cert_from_pemder(str(cert))], allow_fetching=False)
        details = []
        ok = True
        for sig in sigs:
            st = validate_pdf_signature(sig, vc)
            details.append(f"{sig.field_name}: intact={st.intact} valid={st.valid} trusted={st.trusted} "
                           f"coverage={st.coverage.name} modification={st.modification_level.name} "
                           f"docmdp_ok={st.docmdp_ok}")
            ok &= bool(st.intact and st.valid and st.coverage.name == "ENTIRE_REVISION")
        return ("pass: " if ok else "fail: ") + "; ".join(details)


# ---------------------------------------------------------------------------- readers


def expected_listing(before, case, popup_type):
    """The reader's listing of the input, transformed by the manifest's changes.

    Keys are (page, ref, type) → contents. Popup contents are ignored (readers show the parent's)."""
    removed = {ref_key(r)[0] for r in case["removed"]}
    edited = {ref_key(e["ref"])[0]: e["contents"] for e in case["edited"]}
    exp = {}
    for a in before:
        if a["ref"] in removed:
            continue
        contents = edited.get(a["ref"], a["contents"])
        exp[(a["page"], a["ref"], a["type"])] = None if a["type"] == popup_type else contents
    for a in case["added"]:
        exp[(a["page"], ref_key(a["ref"])[0], a["subtype"])] = a["contents"]
    return exp


def actual_listing(after, popup_type):
    return {(a["page"], a["ref"], a["type"]): (None if a["type"] == popup_type else a["contents"]) for a in after}


def compare_listing(exp, act):
    if exp == act:
        return None
    missing = [k for k in exp if k not in act]
    extra = [k for k in act if k not in exp]
    wrong = [k for k in exp if k in act and exp[k] != act[k]]
    return f"missing={missing[:3]} extra={extra[:3]} contents-differ={wrong[:3]}"


def page_geometry(path, index):
    import pikepdf

    with pikepdf.open(path, inherit_page_attributes=False) as pdf:
        page = pdf.pages[index]
        node, rotate = page.obj, 0
        while node is not None:
            if "/Rotate" in node:
                rotate = int(node.Rotate)
                break
            node = node.get("/Parent")
        box = [float(v) for v in page.cropbox]
        return box, rotate % 360


def to_pixels(rect, box, rotate):
    cx0, cy0, cx1, cy1 = min(box[0], box[2]), min(box[1], box[3]), max(box[0], box[2]), max(box[1], box[3])

    def pt(x, y):
        return {0: (x - cx0, cy1 - y), 90: (y - cy0, x - cx0),
                180: (cx1 - x, y - cy0), 270: (cy1 - y, cx1 - x)}[rotate]

    (ax, ay), (bx, by) = pt(rect[0], rect[1]), pt(rect[2], rect[3])
    return min(ax, bx), min(ay, by), max(ax, bx), max(ay, by)


def pixels(png, box):
    from PIL import Image

    with Image.open(png) as im:
        im = im.convert("RGB")
        x0, y0, x1, y1 = (int(round(v)) for v in box)
        crop = im.crop((x0 + 2, y0 + 2, max(x0 + 3, x1 - 2), max(y0 + 3, y1 - 2)))
        px = list(crop.get_flattened_data() if hasattr(crop, "get_flattened_data") else crop.getdata())
        wide = im.crop((max(0, x0 - 2), max(0, y0 - 2), x1 + 2, y1 + 2))
        wpx = list(wide.get_flattened_data() if hasattr(wide, "get_flattened_data") else wide.getdata())
    n = len(px)
    mean = tuple(sum(p[i] for p in px) / n for i in range(3))
    # Strongly tinted pixels (red minus blue at least 50): a thin red or yellow line raises the
    # count even when it is antialiased across two pixel rows; black text and white paper don't.
    tinted = sum(1 for p in wpx if p[0] - p[2] >= 50)
    return mean, tinted


def render_probes(case, render):
    """Renders each probe's page before and after. A highlight must tint its whole area; an
    underline or strike-out ("line") must add strongly tinted pixels along the quad."""
    results = []
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for i, probe in enumerate(case["probes"]):
            page = probe["page"]
            box, rotate = page_geometry(case["output"], page)
            px = to_pixels(probe["rect"], box, rotate)
            before = tmp / f"b{i}.png"
            after = tmp / f"a{i}.png"
            err_before = render(case["input"], page, before)
            err_after = render(case["output"], page, after)
            added = new_messages(err_before or [], err_after or [])
            if added:
                return False, f"renderer complained: {'; '.join(added[:3])}"
            (rb, gb, bb), tb = pixels(before, px)
            (ra, ga, ba), ta = pixels(after, px)
            if probe.get("kind", "highlight") == "line":
                width = abs(px[2] - px[0])
                drawn = ta - tb >= max(5, int(width * 0.3))
                results.append((drawn, f"p{page + 1} line tinted px {tb}->{ta}"))
            else:
                drawn = (bb - ba) >= 40 and ra >= ba + 40
                results.append((drawn, f"p{page + 1} blue {bb:.0f}->{ba:.0f}"))
    ok = all(d for d, _ in results)
    return ok, ", ".join(s for _, s in results)


def render_status(case, render):
    if not case["probes"]:
        return "n/a: no markup added"
    ok, detail = render_probes(case, render)
    if detail.startswith("renderer complained"):
        return "fail: " + detail
    if not case.get("appearanceStreams", True):
        return f"info: {'drawn' if ok else 'NOT drawn'} without /AP ({detail})"
    return ("pass: markup drawn (" if ok else "fail: markup not drawn (") + detail + ")"


def check_mupdf(case):
    if not shutil.which("mutool"):
        return "skip: mutool not installed"
    missing = have_python_libs()
    if missing:
        return missing

    def listing(path):
        r = subprocess.run(["mutool", "run", str(HERE / "mupdf-annots.js"), path], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"mutool exit {r.returncode}: {r.stderr.strip()[:200]}")
        return json.loads(r.stdout), messages(r.stderr, path)

    try:
        (before, warn_before), (after, warn_after) = listing(case["input"]), listing(case["output"])
    except RuntimeError as e:
        return f"fail: {e}"
    added = new_messages(warn_before, warn_after)
    if added:
        return f"fail: mutool: {'; '.join(added[:3])}"
    diff = compare_listing(expected_listing(before, case, "Popup"), actual_listing(after, "Popup"))
    if diff:
        return f"fail: annotations differ: {diff}"

    def render(src, page, dst):
        r = subprocess.run(["mutool", "draw", "-q", "-r", "72", "-o", str(dst), src, str(page + 1)],
                           capture_output=True, text=True)
        return messages(r.stderr, src) if r.returncode == 0 else [f"exit {r.returncode} {r.stderr.strip()}"]

    status = render_status(case, render)
    if status.startswith("fail"):
        return status
    return f"pass: {len(after)} annots listed; draw {status}"


def check_poppler(case):
    if not shutil.which("pdftoppm"):
        return "skip: pdftoppm (poppler) not installed"
    missing = have_python_libs()
    if missing:
        return missing

    def render(src, page, dst):
        prefix = str(dst)[:-4]
        r = subprocess.run(["pdftoppm", "-r", "72", "-f", str(page + 1), "-l", str(page + 1), "-png", "-singlefile",
                            src, prefix], capture_output=True, text=True)
        return messages(r.stderr, src) if r.returncode == 0 else [f"exit {r.returncode} {r.stderr.strip()}"]

    status = render_status(case, render)
    if status.startswith("n/a"):
        return status
    return status


def check_pdfjs(case):
    if not shutil.which("node"):
        return "skip: node not installed"
    if not (HERE / "node_modules" / "pdfjs-dist").exists():
        return "skip: pdfjs-dist not installed; run scripts/corpus/bootstrap"

    def listing(path):
        r = subprocess.run(["node", str(HERE / "pdfjs-annots.mjs"), path], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"node exit {r.returncode}: {r.stderr.strip()[:300]}")
        data = json.loads(r.stdout)
        return [{"page": a["page"], "ref": a["ref"], "type": a["subtype"], "contents": a["contents"],
                 "hasAP": a["hasAppearance"]} for a in data["annotations"]], data["warnings"]

    try:
        (before, warn_before), (after, warn_after) = listing(case["input"]), listing(case["output"])
    except RuntimeError as e:
        return f"fail: {e}"
    added = new_messages(warn_before, warn_after)
    if added:
        return f"fail: pdf.js warnings: {added[:3]}"
    diff = compare_listing(expected_listing(before, case, "Popup"), actual_listing(after, "Popup"))
    if diff:
        return f"fail: annotations differ: {diff}"
    if not (HERE / "node_modules" / "@napi-rs" / "canvas").exists():
        return "skip: pdf.js render needs @napi-rs/canvas (optional dependency of pdfjs-dist); run scripts/corpus/bootstrap"
    missing = have_python_libs()
    if missing:
        return f"skip: pdf.js render needs Pillow from the .venv ({missing})"

    def render(src, page, dst):
        r = subprocess.run(["node", str(HERE / "pdfjs-annots.mjs"), src, "--render", str(page), str(dst)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return [f"node exit {r.returncode}: {r.stderr.strip()[:200]}"]
        return json.loads(r.stdout)["warnings"]

    status = render_status(case, render)
    if status.startswith("fail"):
        return status
    return f"pass: {len(after)} annots via getAnnotations(); render {status}"


def check_refused(case):
    if not case.get("expectError"):
        return "n/a"
    if case.get("output"):
        return "fail: writer produced output for a file it must refuse"
    if case.get("error") == case["expectError"]:
        return f"pass: {case['error']}"
    return f"fail: error {case.get('error')!r}, expected {case['expectError']!r}"


FUNCS = {
    "prefix": check_prefix, "qpdf": check_qpdf, "objects": check_objects, "fields": check_fields,
    "signature": check_signature, "mupdf": check_mupdf, "poppler": check_poppler, "pdfjs": check_pdfjs,
    "refused": check_refused,
}


def run(case, check):
    if check == "refused":
        return check_refused(case)
    if case.get("expectError"):
        return "n/a: refused by design"
    if not case.get("output"):
        return f"fail: writer error {case.get('error')}"
    try:
        return FUNCS[check](case)
    except Exception as e:  # a crash in a check is a failure, never a pass
        return f"fail: {type(e).__name__}: {e}"


def markdown(manifest, results, checks):
    lines = ["| File | " + " | ".join(TITLES[c] for c in checks) + " |",
             "|---|" + "---|" * len(checks)]
    for case in manifest["cases"]:
        row = []
        for c in checks:
            s = results[case["name"]][c]
            word = s.split(":")[0]
            row.append({"pass": "✅", "fail": "❌ FAIL", "skip": "⏭ skip", "n/a": "—", "info": "ℹ️"}.get(word, word))
        lines.append(f"| `{case['name']}` | " + " | ".join(row) + " |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--check", action="append", choices=CHECKS + ["all"])
    ap.add_argument("--json", action="store_true", help="print a JSON report")
    ap.add_argument("--markdown", action="store_true", help="print a Markdown results table")
    args = ap.parse_args()
    checks = CHECKS if not args.check or "all" in args.check else args.check
    manifest = json.loads(Path(args.manifest).read_text())
    results = {c["name"]: {k: run(c, k) for k in checks} for c in manifest["cases"]}
    if args.json:
        print(json.dumps({"results": results}, indent=1, ensure_ascii=False))
    elif args.markdown:
        print(markdown(manifest, results, checks))
    else:
        for name, rs in results.items():
            print(name)
            for k, v in rs.items():
                print(f"  {k:10} {v}")
    statuses = [v.split(":")[0] for rs in results.values() for v in rs.values()]
    counts = {s: statuses.count(s) for s in sorted(set(statuses))}
    print("verify: " + ", ".join(f"{n} {s}" for s, n in counts.items()), file=sys.stderr)
    # Exit 1 on any failure, 2 if anything was skipped, so a missing tool is never a silent pass.
    sys.exit(1 if counts.get("fail") else 2 if counts.get("skip") else 0)


if __name__ == "__main__":
    main()
