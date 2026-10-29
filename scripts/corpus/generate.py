#!/usr/bin/env python3
"""Generates the redistributable test PDF collection in Tests/Corpus/public/.

Every file is produced from scratch by this script (reportlab, qpdf, MuPDF,
pikepdf, pyHanko or the small hand-written assembler below). Run it through the
`generate` wrapper, which uses the repo-root .venv.
"""
from __future__ import annotations

import datetime
import os
import shutil
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "Tests" / "Corpus" / "public"

PARAGRAPHS = [
    "Lectern test corpus. This page exists so that the incremental writer has real text to highlight.",
    "The quick brown fox jumps over the lazy dog while the reader keeps its place on the page.",
    "Annotations are appended as an incremental update; the original bytes must stay untouched.",
    "Forms, signatures and earlier revisions must survive a save without a single changed byte.",
]


def run(*args: str) -> None:
    subprocess.run(list(args), check=True)


def require(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        sys.exit(f"generate: required tool '{tool}' not found on PATH (brew install qpdf mupdf-tools)")
    return path


# ---------------------------------------------------------------------------
# reportlab-based documents (classic cross-reference tables)


def reportlab_text_pdf(path: Path, pages: int = 2, title: str = "Lectern corpus") -> None:
    from reportlab.lib.pagesizes import LETTER
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(path), pagesize=LETTER, invariant=1)
    c.setTitle(title)
    c.setAuthor("Lectern corpus generator")
    for p in range(pages):
        c.setFont("Helvetica-Bold", 18)
        c.drawString(72, 720, f"{title}: page {p + 1}")
        c.setFont("Helvetica", 12)
        y = 680
        for para in PARAGRAPHS:
            c.drawString(72, y, para[:90])
            y -= 24
        c.showPage()
    c.save()


def acroform_pdf(path: Path) -> None:
    from reportlab.lib.pagesizes import LETTER
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(path), pagesize=LETTER, invariant=1)
    c.setTitle("Lectern corpus: filled form")
    c.setFont("Helvetica-Bold", 18)
    c.drawString(72, 720, "Filled AcroForm")
    c.setFont("Helvetica", 12)
    c.drawString(72, 680, PARAGRAPHS[0][:90])
    c.drawString(72, 640, "Name:")
    c.acroForm.textfield(name="name", value="Ada Lovelace", x=140, y=630, width=220, height=22)
    c.drawString(72, 600, "City:")
    c.acroForm.textfield(name="city", value="Zürich (ünïcode)", x=140, y=590, width=220, height=22)
    c.drawString(72, 560, "Subscribed:")
    c.acroForm.checkbox(name="subscribed", checked=True, x=160, y=555, size=16)
    c.drawString(72, 530, "Unchecked:")
    c.acroForm.checkbox(name="declined", checked=False, x=160, y=525, size=16)
    c.showPage()
    c.drawString(72, 720, "Second page without fields.")
    c.showPage()
    c.save()


# ---------------------------------------------------------------------------
# Minimal hand-written PDF assembler, for structures the libraries won't emit
# (hybrid cross-reference files, nested page trees, object streams we control).


class MiniPDF:
    def __init__(self) -> None:
        self.objects: dict[int, bytes] = {}

    def add(self, num: int, body: str | bytes) -> None:
        self.objects[num] = body.encode("latin-1") if isinstance(body, str) else body

    @staticmethod
    def stream(dict_body: str, data: bytes, compress: bool = False) -> bytes:
        if compress:
            data = zlib.compress(data)
            dict_body += " /Filter /FlateDecode"
        return f"<< {dict_body} /Length {len(data)} >>\nstream\n".encode("latin-1") + data + b"\nendstream"

    def write(self, path: Path, mode: str, root: int, info: int | None, compressed: set[int] = frozenset()) -> None:
        """mode: 'table', or 'hybrid' (table + /XRefStm for objects in an object stream)."""
        size = max(self.objects) + 1
        out = bytearray(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
        offsets: dict[int, int] = {}
        objstm_index: dict[int, tuple[int, int]] = {}
        objstm_num = size
        xrefstm_num = size + 1
        if compressed:
            header, body = [], bytearray()
            for i, num in enumerate(sorted(compressed)):
                header.append(f"{num} {len(body)}")
                body += self.objects[num] + b"\n"
                objstm_index[num] = (objstm_num, i)
            head = (" ".join(header) + "\n").encode()
            data = head + bytes(body)
            self.objects[objstm_num] = self.stream(
                f"/Type /ObjStm /N {len(compressed)} /First {len(head)}", data, compress=True
            )
            size = objstm_num + 1
        for num in sorted(self.objects):
            if num in compressed:
                continue
            offsets[num] = len(out)
            out += f"{num} 0 obj\n".encode() + self.objects[num] + b"\nendobj\n"
        xrefstm_offset = None
        if mode == "hybrid":
            assert compressed
            # Cross-reference stream that lists only the compressed objects.
            rows = bytearray()
            nums = sorted(objstm_index)
            index = []
            for num in nums:
                index += [num, 1]
                stm, idx = objstm_index[num]
                rows += bytes([2]) + stm.to_bytes(4, "big") + idx.to_bytes(2, "big")
            xrefstm_offset = len(out)
            body = self.stream(
                f"/Type /XRef /Size {xrefstm_num + 1} /W [1 4 2] /Index [{' '.join(map(str, index))}]",
                bytes(rows),
            )
            out += f"{xrefstm_num} 0 obj\n".encode() + body + b"\nendobj\n"
            offsets[xrefstm_num] = xrefstm_offset
            size = xrefstm_num + 1
        xref_offset = len(out)
        out += b"xref\n"
        # Compressed objects are left out of the table entirely: qpdf, MuPDF and pdf.js all let a
        # free table entry hide the /XRefStm entry for the same object, so they must not be listed.
        entries = {0: b"0000000000 65535 f\r\n"}
        for num, off in offsets.items():
            entries[num] = f"{off:010d} 00000 n\r\n".encode()
        nums = sorted(entries)
        run_start = 0
        for i in range(1, len(nums) + 1):
            if i == len(nums) or nums[i] != nums[i - 1] + 1:
                block = nums[run_start:i]
                out += f"{block[0]} {len(block)}\n".encode()
                for num in block:
                    out += entries[num]
                run_start = i
        trailer = f"<< /Size {size} /Root {root} 0 R"
        if info:
            trailer += f" /Info {info} 0 R"
        trailer += " /ID [<4c6563746572e6e5636f72707573aa01> <4c6563746572e6e5636f72707573aa01>]"
        if xrefstm_offset is not None:
            trailer += f" /XRefStm {xrefstm_offset}"
        trailer += " >>"
        out += f"trailer\n{trailer}\nstartxref\n{xref_offset}\n%%EOF\n".encode()
        path.write_bytes(bytes(out))


def text_content(lines: list[str], top: float) -> bytes:
    ops = ["BT", "/F1 12 Tf", f"72 {top:.0f} Td", "14 TL"]
    for line in lines:
        escaped = line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        ops.append(f"({escaped}) Tj T*")
    ops.append("ET")
    return "\n".join(ops).encode("latin-1")


def hybrid_pdf(path: Path) -> None:
    """Classic table + /XRefStm. Page objects and the font live in an object stream."""
    m = MiniPDF()
    m.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    m.add(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    m.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
    m.add(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
    m.add(5, MiniPDF.stream("", text_content(["Hybrid cross-reference file, page 1."] + PARAGRAPHS, 720), compress=True))
    m.add(6, MiniPDF.stream("", text_content(["Hybrid cross-reference file, page 2."] + PARAGRAPHS, 720), compress=True))
    m.add(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    m.add(8, "<< /Title (Lectern corpus: hybrid xref) /Producer (Lectern MiniPDF) >>")
    m.write(path, "hybrid", root=1, info=8, compressed={2, 3, 4, 7})


def mixed_sizes_pdf(path: Path) -> None:
    """Five pages of different sizes and rotations, in a nested /Pages tree."""
    m = MiniPDF()
    sizes = [
        ("US Letter portrait", "[0 0 612 792]", 0),
        ("A4 landscape", "[0 0 842 595]", 0),
        ("A5 portrait", "[0 0 420 595]", 0),
        ("Legal, /Rotate 90", "[0 0 612 1008]", 90),
        ("Offset MediaBox", "[100 100 712 892]", 0),
    ]
    m.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    # Root has one direct page and two intermediate /Pages nodes.
    m.add(2, "<< /Type /Pages /Kids [10 0 R 3 0 R 4 0 R] /Count 5 /Resources << /Font << /F1 9 0 R >> >> >>")
    m.add(3, "<< /Type /Pages /Parent 2 0 R /Kids [11 0 R 12 0 R] /Count 2 >>")
    m.add(4, "<< /Type /Pages /Parent 2 0 R /Kids [13 0 R 14 0 R] /Count 2 >>")
    m.add(9, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    parents = [2, 3, 3, 4, 4]
    for i, (label, box, rot) in enumerate(sizes):
        page_num, content_num = 10 + i, 20 + i
        coords = [float(v) for v in box.strip("[]").split()]
        top = coords[3] - 72
        x0 = coords[0]
        lines = [f"Mixed page sizes, page {i + 1}: {label}"] + PARAGRAPHS[:2]
        content = text_content(lines, top).replace(b"72 ", f"{x0 + 72:.0f} ".encode(), 1)
        m.add(content_num, MiniPDF.stream("", content, compress=True))
        rotate = f" /Rotate {rot}" if rot else ""
        # Resources are inherited from the root /Pages node.
        m.add(page_num, f"<< /Type /Page /Parent {parents[i]} 0 R /MediaBox {box}{rotate} /Contents {content_num} 0 R >>")
    m.add(30, "<< /Title (Lectern corpus: mixed page sizes) /Producer (Lectern MiniPDF) >>")
    m.write(path, "table", root=1, info=30)


# ---------------------------------------------------------------------------


def xref_stream_pdf(tmp: Path, path: Path) -> None:
    """Cross-reference stream + object streams, with an indirect /Annots array holding a Link."""
    import pikepdf

    base = tmp / "xs-base.pdf"
    reportlab_text_pdf(base, pages=3, title="Lectern corpus: xref stream")
    with pikepdf.open(base) as pdf:
        page = pdf.pages[0]
        link = pdf.make_indirect(pikepdf.Dictionary(
            Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Link,
            Rect=pikepdf.Array([72, 400, 300, 420]), Border=pikepdf.Array([0, 0, 0]),
            A=pikepdf.Dictionary(S=pikepdf.Name.URI, URI=pikepdf.String("https://example.org/")),
        ))
        page.obj.Annots = pdf.make_indirect(pikepdf.Array([link]))
        pdf.save(path, object_stream_mode=pikepdf.ObjectStreamMode.generate,
                 compress_streams=True, deterministic_id=True, linearize=False)


def signed_pdf(tmp: Path, path: Path) -> None:
    """Approval signature from a throwaway self-signed certificate."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Lectern Corpus Test Signer")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True, key_encipherment=False,
                                     data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                     crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_pem = tmp / "signer-key.pem"
    cert_pem = tmp / "signer-cert.pem"
    key_pem.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    cert_pem.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    # The certificate is public and needed by verify to build the trust root.
    shutil.copy(cert_pem, path.with_suffix(".cert.pem"))

    base = tmp / "signed-base.pdf"
    reportlab_text_pdf(base, pages=2, title="Lectern corpus: signed")
    signer = signers.SimpleSigner.load(str(key_pem), str(cert_pem))
    with base.open("rb") as inf, path.open("wb") as outf:
        w = IncrementalPdfFileWriter(inf)
        meta = signers.PdfSignatureMetadata(field_name="Signature1", reason="Lectern corpus test signature")
        spec = fields.SigFieldSpec(sig_field_name="Signature1", on_page=0, box=(72, 72, 272, 132))
        signers.sign_pdf(w, meta, signer=signer, new_field_spec=spec, output=outf)


def forms_pdf(tmp: Path, path: Path) -> None:
    base = tmp / "forms-base.pdf"
    acroform_pdf(base)
    # Repack into object streams so the widgets and page sit inside compressed objects.
    run("qpdf", "--object-streams=generate", "--deterministic-id", base.as_posix(), path.as_posix())


def third_party_pdf(tmp: Path, path: Path) -> None:
    base = tmp / "tp-base.pdf"
    reportlab_text_pdf(base, pages=2, title="Lectern corpus: third-party annotations")
    run("mutool", "run", (HERE / "mupdf-annotate.js").as_posix(), "third-party", base.as_posix(), path.as_posix())


def incremental_pdf(tmp: Path, path: Path) -> None:
    base = tmp / "inc-base.pdf"
    reportlab_text_pdf(base, pages=2, title="Lectern corpus: earlier incremental update")
    shutil.copy(base, path)
    run("mutool", "run", (HERE / "mupdf-annotate.js").as_posix(), "incremental", path.as_posix(), path.as_posix())
    if not path.read_bytes().startswith(base.read_bytes()):
        sys.exit("generate: MuPDF did not write an incremental update")


def encrypted_pdfs(tmp: Path) -> None:
    base = tmp / "enc-base.pdf"
    reportlab_text_pdf(base, pages=1, title="Lectern corpus: encrypted")
    run("qpdf", "--encrypt", "user-pass", "owner-pass", "256", "--",
        base.as_posix(), (OUT / "encrypted-aes256.pdf").as_posix())
    # Empty user password: opens without a prompt, but annotation is forbidden.
    run("qpdf", "--encrypt", "", "owner-pass", "256", "--modify=none", "--annotate=n", "--",
        base.as_posix(), (OUT / "encrypted-aes256-owner-only.pdf").as_posix())


def main() -> None:
    for tool in ("qpdf", "mutool"):
        require(tool)
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        reportlab_text_pdf(OUT / "classic-xref.pdf", pages=2, title="Lectern corpus: classic xref")
        xref_stream_pdf(tmp, OUT / "xref-stream-objstm.pdf")
        incremental_pdf(tmp, OUT / "incremental-existing.pdf")
        signed_pdf(tmp, OUT / "signed-approval.pdf")
        forms_pdf(tmp, OUT / "acroform-filled.pdf")
        third_party_pdf(tmp, OUT / "third-party-annots.pdf")
        mixed_sizes_pdf(OUT / "mixed-page-sizes.pdf")
        hybrid_pdf(OUT / "hybrid-xref.pdf")
        encrypted_pdfs(tmp)
    for f in sorted(OUT.glob("*.pdf")):
        print(f"{f.stat().st_size:>8}  {f.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
