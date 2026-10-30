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

    def write(self, path: Path, mode: str, root: int, info: int | None, compressed: set[int] = frozenset(),
              encrypt: int | None = None, file_id: bytes | None = None) -> None:
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
        ident = (file_id or bytes.fromhex("4c6563746572e6e5636f72707573aa01")).hex()
        trailer += f" /ID [<{ident}> <{ident}>]"
        if encrypt:
            trailer += f" /Encrypt {encrypt} 0 R"
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


def signed_pdf(tmp: Path, path: Path, certify: bool = False) -> None:
    """Approval signature from a throwaway self-signed certificate, or with `certify` a
    certification signature (DocMDP, P=2: form filling only, so annotations are not permitted)."""
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
    key_pem = tmp / f"{path.stem}-key.pem"
    cert_pem = tmp / f"{path.stem}-cert.pem"
    key_pem.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    cert_pem.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    # The certificate is public and needed by verify to build the trust root.
    shutil.copy(cert_pem, path.with_suffix(".cert.pem"))

    base = tmp / f"{path.stem}-base.pdf"
    reportlab_text_pdf(base, pages=2, title="Lectern corpus: certified" if certify else "Lectern corpus: signed")
    signer = signers.SimpleSigner.load(str(key_pem), str(cert_pem))
    with base.open("rb") as inf, path.open("wb") as outf:
        w = IncrementalPdfFileWriter(inf)
        if certify:
            meta = signers.PdfSignatureMetadata(field_name="Signature1", reason="Lectern corpus test certification",
                                                certify=True, docmdp_permissions=fields.MDPPerm.FILL_FORMS)
        else:
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


def linearized_pdf(tmp: Path, path: Path) -> None:
    """A linearized ("Fast Web View") file with consistent hint tables, from qpdf."""
    base = tmp / "lin-base.pdf"
    reportlab_text_pdf(base, pages=4, title="Lectern corpus: linearized")
    run("qpdf", "--linearize", "--deterministic-id", base.as_posix(), path.as_posix())
    run("qpdf", "--check-linearization", path.as_posix())


def encrypted_pdfs(tmp: Path) -> None:
    base = tmp / "enc-base.pdf"
    reportlab_text_pdf(base, pages=1, title="Lectern corpus: encrypted")
    run("qpdf", "--encrypt", "user-pass", "owner-pass", "256", "--",
        base.as_posix(), (OUT / "encrypted-aes256.pdf").as_posix())
    # Empty user password: opens without a prompt, but annotation is forbidden.
    run("qpdf", "--encrypt", "", "owner-pass", "256", "--modify=none", "--annotate=n", "--",
        base.as_posix(), (OUT / "encrypted-aes256-owner-only.pdf").as_posix())


# ---------------------------------------------------------------------------
# Encrypted files that Lectern saves into (M7). Every supported Standard-handler variant, plus the
# ones that stay refused. Passwords are listed in Tests/Corpus/README.md and in the Swift corpus
# cases; a fixture with no user password opens without a prompt.

ENCRYPTED_OWNER = "owner-pass"


def qpdf_encrypt(src: Path, dst: Path, user: str, bits: int, *options: str, weak: bool = False,
                 object_streams: bool = False) -> None:
    """`qpdf --encrypt` with the flag form, so any text (an empty or a non-ASCII password) is passed
    exactly. The output isn't reproducible: the /ID and the salts change on every run."""
    args = ["qpdf"]
    if weak:
        args.append("--allow-weak-crypto")
    if object_streams:
        args.append("--object-streams=generate")
    args += ["--encrypt", f"--user-password={user}", f"--owner-password={ENCRYPTED_OWNER}",
             f"--bits={bits}", *options, "--", src.as_posix(), dst.as_posix()]
    run(*args)
    check = ["qpdf", f"--password={user or ENCRYPTED_OWNER}", "--check", dst.as_posix()]
    run(*check)


def encrypted_base(tmp: Path, name: str, title: str, pages: int = 2) -> Path:
    base = tmp / f"{name}-base.pdf"
    reportlab_text_pdf(base, pages=pages, title=title)
    return base


def encrypted_r2(tmp: Path) -> None:
    """R2, RC4 with a 40-bit key, user and owner passwords."""
    base = encrypted_base(tmp, "r2", "Lectern corpus: encrypted R2 RC4-40")
    qpdf_encrypt(base, OUT / "encrypted-r2-rc4-40.pdf", "user-pass", 40, weak=True)


def encrypted_r3_annotated(tmp: Path) -> None:
    """R3, RC4 128-bit, no user password; annotations written by another app (MuPDF) before
    encrypting, so edits and deletes of existing annotations run against decrypted descriptors."""
    base = tmp / "r3-annotated-base.pdf"
    third_party_pdf(tmp, base)
    qpdf_encrypt(base, OUT / "encrypted-r3-rc4-annotated.pdf", "", 128, "--use-aes=n", weak=True)


def encrypted_r4_rc4(tmp: Path) -> None:
    """R4 with the /V2 (RC4) crypt filter, and a non-ASCII user password inside PDFDocEncoding."""
    base = encrypted_base(tmp, "r4-rc4", "Lectern corpus: encrypted R4 RC4")
    qpdf_encrypt(base, OUT / "encrypted-r4-rc4.pdf", "pässwörd", 128, "--use-aes=n", "--force-V4", weak=True)


def encrypted_r4_aes_objstm(tmp: Path) -> None:
    """R4 with /AESV2, a cross-reference stream and object streams holding the pages."""
    base = encrypted_base(tmp, "r4-aes", "Lectern corpus: encrypted R4 AES-128", pages=3)
    qpdf_encrypt(base, OUT / "encrypted-r4-aes128-objstm.pdf", "user-pass", 128, "--use-aes=y", object_streams=True)


def encrypted_r4_cleartext_metadata(tmp: Path) -> None:
    """R4 AES with /EncryptMetadata false: the XMP stream stays in the clear."""
    import pikepdf

    plain = encrypted_base(tmp, "r4-meta", "Lectern corpus: encrypted R4 cleartext metadata")
    base = tmp / "r4-meta-xmp.pdf"
    with pikepdf.open(plain) as pdf:
        with pdf.open_metadata(set_pikepdf_as_editor=False) as meta:
            meta["dc:title"] = "Lectern corpus: cleartext metadata"
        pdf.save(base, deterministic_id=True)
    qpdf_encrypt(base, OUT / "encrypted-r4-cleartext-metadata.pdf", "", 128, "--use-aes=y", "--cleartext-metadata")


def encrypted_r6_objstm_restricted(tmp: Path) -> None:
    """R6, no user password, object streams; printing and copying forbidden, commenting allowed."""
    base = encrypted_base(tmp, "r6-restricted", "Lectern corpus: encrypted R6 restricted", pages=3)
    qpdf_encrypt(base, OUT / "encrypted-r6-objstm-restricted.pdf", "", 256,
                 "--modify=annotate", "--print=none", "--extract=n", object_streams=True)


def encrypted_r6_unicode(tmp: Path) -> None:
    """R6 with a non-ASCII user password (precomposed, so NFC and NFKC agree)."""
    base = encrypted_base(tmp, "r6-unicode", "Lectern corpus: encrypted R6 unicode password")
    qpdf_encrypt(base, OUT / "encrypted-r6-unicode.pdf", "Grüße-ключ", 256)


def encrypted_r5(tmp: Path) -> None:
    """The deprecated R5 (Acrobat 9's AES-256): still refused."""
    base = encrypted_base(tmp, "r5", "Lectern corpus: encrypted R5", pages=1)
    qpdf_encrypt(base, OUT / "encrypted-r5.pdf", "user-pass", 256, "--force-R5", weak=True)


def throwaway_certificate(tmp: Path, name: str, common_name: str, encipherment: bool = False):
    """A self-signed RSA-2048 certificate and its private key, written to tmp (never committed)."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True, key_encipherment=encipherment,
                                     data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                     crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_pem, cert_pem = tmp / f"{name}-key.pem", tmp / f"{name}-cert.pem"
    key_pem.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    cert_pem.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return key_pem, cert_pem


def encrypted_signed(tmp: Path) -> None:
    """R6 with no user password, then an approval signature added by pyHanko in an incremental
    update (it encrypts the update with the file's key). Must stay copy-only, signature intact."""
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers

    path = OUT / "encrypted-signed.pdf"
    base = encrypted_base(tmp, "enc-signed", "Lectern corpus: encrypted and signed")
    encrypted = tmp / "enc-signed-encrypted.pdf"
    qpdf_encrypt(base, encrypted, "", 256)
    key_pem, cert_pem = throwaway_certificate(tmp, "enc-signed", "Lectern Corpus Test Signer")
    shutil.copy(cert_pem, path.with_suffix(".cert.pem"))
    signer = signers.SimpleSigner.load(str(key_pem), str(cert_pem))
    with encrypted.open("rb") as inf, path.open("wb") as outf:
        w = IncrementalPdfFileWriter(inf)
        w.encrypt(ENCRYPTED_OWNER)
        meta = signers.PdfSignatureMetadata(field_name="Signature1", reason="Lectern corpus test signature")
        spec = fields.SigFieldSpec(sig_field_name="Signature1", on_page=0, box=(72, 72, 272, 132))
        signers.sign_pdf(w, meta, signer=signer, new_field_spec=spec, output=outf)
    run("qpdf", f"--password={ENCRYPTED_OWNER}", "--check", path.as_posix())


def encrypted_pubkey(tmp: Path) -> None:
    """The public-key security handler (/Adobe.PubSec): still refused. The recipient's private key
    is thrown away, so nothing can open it; it exists to be recognised and refused."""
    from asn1crypto import x509 as asn1_x509
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.pdf_utils.writer import copy_into_new_writer

    base = encrypted_base(tmp, "pubkey", "Lectern corpus: public-key encryption", pages=1)
    _, cert_pem = throwaway_certificate(tmp, "pubkey", "Lectern Corpus Test Recipient", encipherment=True)
    from cryptography import x509 as crypto_x509
    from cryptography.hazmat.primitives import serialization

    der = crypto_x509.load_pem_x509_certificate(cert_pem.read_bytes()).public_bytes(serialization.Encoding.DER)
    with base.open("rb") as inf:
        w = copy_into_new_writer(PdfFileReader(inf))
        w.encrypt_pubkey([asn1_x509.Certificate.load(der)])
        with (OUT / "encrypted-pubkey.pdf").open("wb") as outf:
            w.write(outf)


# R4 with different stream and string filters (/StmF AESV2, /StrF /Identity). qpdf never writes
# that, so this one is assembled by hand (ISO 32000-2 §7.6.4, algorithms 2, 3 and 5) and accepted
# only after qpdf decrypts it cleanly.

PAD = bytes.fromhex("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")


def rc4(key: bytes, data: bytes) -> bytes:
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) % 256
        s[i], s[j] = s[j], s[i]
    out, i, j = bytearray(), 0, 0
    for b in data:
        i = (i + 1) % 256
        j = (j + s[i]) % 256
        s[i], s[j] = s[j], s[i]
        out.append(b ^ s[(s[i] + s[j]) % 256])
    return bytes(out)


def r4_identity_strings_pdf(path: Path) -> None:
    import hashlib

    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    file_id = bytes.fromhex("4c6563746572e6e5636f72707573aa02")
    p_value = -4  # every permission
    user, owner = b"", ENCRYPTED_OWNER.encode()
    # Algorithm 3: /O.
    owner_key = hashlib.md5((owner + PAD)[:32]).digest()
    for _ in range(50):
        owner_key = hashlib.md5(owner_key).digest()
    o_value = rc4(owner_key, (user + PAD)[:32])
    for i in range(1, 20):
        o_value = rc4(bytes(b ^ i for b in owner_key), o_value)
    # Algorithm 2: the file key (EncryptMetadata true, so no 0xFFFFFFFF).
    digest = hashlib.md5((user + PAD)[:32] + o_value + (p_value & 0xFFFFFFFF).to_bytes(4, "little") + file_id).digest()
    for _ in range(50):
        digest = hashlib.md5(digest).digest()
    key = digest[:16]
    # Algorithm 5: /U.
    u_value = rc4(key, hashlib.md5(PAD + file_id).digest())
    for i in range(1, 20):
        u_value = rc4(bytes(b ^ i for b in key), u_value)
    u_value += bytes(16)

    def aes(num: int, data: bytes) -> bytes:
        k = hashlib.md5(key + num.to_bytes(3, "little") + (0).to_bytes(2, "little") + b"sAlT").digest()
        iv = hashlib.md5(b"Lectern IV" + num.to_bytes(4, "big")).digest()  # fixed, so the file is reproducible
        padder = padding.PKCS7(128).padder()
        padded = padder.update(data) + padder.finalize()
        enc = Cipher(algorithms.AES(k), modes.CBC(iv)).encryptor()
        return iv + enc.update(padded) + enc.finalize()

    def stream(num: int, extra: str, data: bytes) -> bytes:
        body = aes(num, zlib.compress(data))
        return f"<< {extra} /Filter /FlateDecode /Length {len(body)} >>\nstream\n".encode() + body + b"\nendstream"

    m = MiniPDF()
    m.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    m.add(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    m.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R "
             "/Resources << /Font << /F1 7 0 R >> >> /Annots [9 0 R] >>")
    m.add(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
    m.add(5, stream(5, "", text_content(["Identity string filter, page 1."] + PARAGRAPHS, 720)))
    m.add(6, stream(6, "", text_content(["Identity string filter, page 2."] + PARAGRAPHS, 720)))
    m.add(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    # Strings stay in the clear under /StrF /Identity: this note's /Contents and /NM are plaintext.
    m.add(9, "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /P 3 0 R /NM (other-app-note-1) "
             "/Contents (A note in the clear) /C [1 1 0] /Name /Comment >>")
    m.add(8, "<< /Title (Lectern corpus: R4 identity string filter) /Producer (Lectern MiniPDF) >>")
    o_hex, u_hex = o_value.hex(), u_value.hex()
    m.add(10, f"<< /Filter /Standard /V 4 /R 4 /Length 128 /P {p_value} /O <{o_hex}> /U <{u_hex}> "
              "/CF << /StdCF << /Type /CryptFilter /CFM /AESV2 /AuthEvent /DocOpen /Length 16 >> >> "
              "/StmF /StdCF /StrF /Identity >>")
    m.write(path, "table", root=1, info=8, encrypt=10, file_id=file_id)
    run("qpdf", "--check", path.as_posix())


def r3_rc4_56_pdf(path: Path) -> None:
    """R3, RC4 with a 56-bit key (/Length 56), user `user-pass`, owner `owner-pass`.

    A key shorter than 16 bytes tells the owner-key derivations apart: the 50 MD5 rounds of
    algorithm 3 hash the first n bytes in qpdf, PDFKit, Acrobat and PDFBox, all 16 in pdf.js. This
    file follows the first (and qpdf accepts the owner password). Page 1 also holds strings of its
    own (a /PieceInfo date) and a direct annotation dictionary inside /Annots, so a rewrite of the
    page must re-encrypt them with the page's key."""
    import hashlib

    n = 7
    file_id = bytes.fromhex("4c6563746572e6e5636f72707573aa03")
    p_value = -4
    user, owner = b"user-pass", ENCRYPTED_OWNER.encode()
    md5 = lambda b: hashlib.md5(b).digest()
    # Algorithm 3: /O, with 50 rounds over the first n bytes.
    k = md5((owner + PAD)[:32])
    for _ in range(50):
        k = md5(k[:n])
    o_value = (user + PAD)[:32]
    for i in range(20):
        o_value = rc4(bytes(b ^ i for b in k[:n]), o_value)
    # Algorithm 2: the file key.
    h = md5((user + PAD)[:32] + o_value + (p_value & 0xFFFFFFFF).to_bytes(4, "little") + file_id)
    for _ in range(50):
        h = md5(h[:n])
    key = h[:n]
    # Algorithm 5: /U.
    u_value = md5(PAD + file_id)
    for i in range(20):
        u_value = rc4(bytes(b ^ i for b in key), u_value)
    u_value += bytes(16)

    def object_key(num: int) -> bytes:
        return md5(key + num.to_bytes(3, "little") + (0).to_bytes(2, "little"))[: min(n + 5, 16)]

    def string(num: int, text: str) -> str:
        return "<" + rc4(object_key(num), text.encode("latin-1")).hex() + ">"

    def stream(num: int, data: bytes) -> bytes:
        body = rc4(object_key(num), zlib.compress(data))
        return f"<< /Filter /FlateDecode /Length {len(body)} >>\nstream\n".encode() + body + b"\nendstream"

    m = MiniPDF()
    m.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    m.add(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    m.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R "
             "/Resources << /Font << /F1 7 0 R >> >> "
             f"/PieceInfo << /Lectern << /LastModified {string(3, 'D:20261030120000Z')} /Private {string(3, 'page-private-data')} >> >> "
             "/Annots [<< /Type /Annot /Subtype /Text /Rect [520 720 540 740] "
             f"/Contents {string(3, 'An inline note from another app')} /NM {string(3, 'inline-note-1')} /C [1 0.8 0] >>] >>")
    m.add(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
    m.add(5, stream(5, text_content(["RC4 with a 56-bit key, page 1."] + PARAGRAPHS, 700)))
    m.add(6, stream(6, text_content(["RC4 with a 56-bit key, page 2."] + PARAGRAPHS, 700)))
    m.add(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    m.add(8, f"<< /Title {string(8, 'Lectern corpus: R3 RC4 56-bit')} /Producer {string(8, 'Lectern MiniPDF')} >>")
    m.add(9, f"<< /Filter /Standard /V 2 /R 3 /Length 56 /P {p_value} /O <{o_value.hex()}> /U <{u_value.hex()}> >>")
    m.write(path, "table", root=1, info=8, encrypt=9, file_id=file_id)
    for password in ("user-pass", ENCRYPTED_OWNER):
        run("qpdf", f"--password={password}", "--check", path.as_posix())


def encrypted_r3_rc4_56(tmp: Path) -> None:
    r3_rc4_56_pdf(OUT / "encrypted-r3-rc4-56.pdf")


def encrypted_r4_identity_strings(tmp: Path) -> None:
    r4_identity_strings_pdf(OUT / "encrypted-r4-identity-strings.pdf")


def main() -> None:
    """`generate` rewrites every file; `generate --only name ...` rewrites just those (the output
    isn't byte-reproducible, so regenerating everything changes files whose cases didn't change)."""
    for tool in ("qpdf", "mutool"):
        require(tool)
    OUT.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[sys.argv.index("--only") + 1:]) if "--only" in sys.argv else None
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        jobs = {
            "classic-xref": lambda: reportlab_text_pdf(OUT / "classic-xref.pdf", pages=2, title="Lectern corpus: classic xref"),
            "xref-stream-objstm": lambda: xref_stream_pdf(tmp, OUT / "xref-stream-objstm.pdf"),
            "incremental-existing": lambda: incremental_pdf(tmp, OUT / "incremental-existing.pdf"),
            "signed-approval": lambda: signed_pdf(tmp, OUT / "signed-approval.pdf"),
            "certified-docmdp": lambda: signed_pdf(tmp, OUT / "certified-docmdp.pdf", certify=True),
            "acroform-filled": lambda: forms_pdf(tmp, OUT / "acroform-filled.pdf"),
            "third-party-annots": lambda: third_party_pdf(tmp, OUT / "third-party-annots.pdf"),
            "mixed-page-sizes": lambda: mixed_sizes_pdf(OUT / "mixed-page-sizes.pdf"),
            "hybrid-xref": lambda: hybrid_pdf(OUT / "hybrid-xref.pdf"),
            "linearized-qpdf": lambda: linearized_pdf(tmp, OUT / "linearized-qpdf.pdf"),
            "encrypted": lambda: encrypted_pdfs(tmp),
            "encrypted-r2-rc4-40": lambda: encrypted_r2(tmp),
            "encrypted-r3-rc4-annotated": lambda: encrypted_r3_annotated(tmp),
            "encrypted-r3-rc4-56": lambda: encrypted_r3_rc4_56(tmp),
            "encrypted-r4-rc4": lambda: encrypted_r4_rc4(tmp),
            "encrypted-r4-aes128-objstm": lambda: encrypted_r4_aes_objstm(tmp),
            "encrypted-r4-cleartext-metadata": lambda: encrypted_r4_cleartext_metadata(tmp),
            "encrypted-r4-identity-strings": lambda: encrypted_r4_identity_strings(tmp),
            "encrypted-r6-objstm-restricted": lambda: encrypted_r6_objstm_restricted(tmp),
            "encrypted-r6-unicode": lambda: encrypted_r6_unicode(tmp),
            "encrypted-signed": lambda: encrypted_signed(tmp),
            "encrypted-pubkey": lambda: encrypted_pubkey(tmp),
            "encrypted-r5": lambda: encrypted_r5(tmp),
        }
        unknown = (only or set()) - set(jobs)
        if unknown:
            sys.exit(f"generate: unknown file(s) {sorted(unknown)}; known: {sorted(jobs)}")
        for name, job in jobs.items():
            if only is None or name in only:
                job()
    for f in sorted(OUT.glob("*.pdf")):
        print(f"{f.stat().st_size:>8}  {f.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
