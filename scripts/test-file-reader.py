#!/usr/bin/env python3
"""Offline real-reader checks. Only generated fixtures in a temporary directory."""
import json
import pathlib
import subprocess
import sys
import tempfile
import uuid
import zipfile
import base64
import struct
import zlib

tool = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/FloatingAIFileTool").resolve()

with tempfile.TemporaryDirectory(prefix="floating-files-") as temp:
    root = pathlib.Path(temp)
    note = root / "Attachments" / str(uuid.uuid4())
    other = root / "Attachments" / str(uuid.uuid4())
    note.mkdir(parents=True)
    other.mkdir(parents=True)
    scratch = root / "scratch" / str(uuid.uuid4())
    def file(ext, data, directory=note):
        path = directory / (str(uuid.uuid4()) + "." + ext)
        path.write_bytes(data)
        return path
    def read(path, page=None):
        args = [str(tool), "read", "--root", str(note), "--scratch", str(scratch), "--path", str(path)]
        if page is not None:
            args += ["--page", str(page)]
        return json.loads(subprocess.run(args, capture_output=True, check=True, timeout=35).stdout)

    text = file("txt", "A text attachment 中文\n".encode())
    assert "中文" in read(text)["text"]
    large = file("txt", ("中文测试" * 30_000).encode())
    result = read(large)
    assert len(result["text"].encode()) < 200_000 and "truncated" in result["text"].lower() and result["truncated"]
    foreign = file("txt", b"OTHER NOTE CANARY", other)
    assert "error" in read(foreign)
    link = note / (str(uuid.uuid4()) + ".txt")
    link.symlink_to(foreign)
    assert "error" in read(link)
    assert "error" in read(note / ".." / other.name / foreign.name)
    directory_link = root / "Attachments" / str(uuid.uuid4())
    directory_link.symlink_to(other, target_is_directory=True)
    assert "error" in read(directory_link / foreign.name)
    assert "error" in read(file("bin", b"\x00\xff\x01"))
    assert "error" in read(file("doc", b"old binary word"))
    print("PASS: text/Unicode limits, unknown formats, sibling/traversal/symlink denial")

    docx = file("docx", b"")
    with zipfile.ZipFile(docx, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Word example 中文</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
    parsed = read(docx)
    assert "Word example 中文" in parsed["text"] and "Table cell" in parsed["text"]
    xlsx = file("xlsx", b"")
    with zipfile.ZipFile(xlsx, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("xl/workbook.xml", '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Results" r:id="rId1"/></sheets></workbook>')
        archive.writestr("xl/_rels/workbook.xml.rels", '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
        archive.writestr("xl/sharedStrings.xml", '<sst><si><t>Revenue</t></si></sst>')
        archive.writestr("xl/worksheets/sheet1.xml", '<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c><c r="C1"><f>B1*2</f><v>84</v></c><c r="D1" t="inlineStr"><is><t>Inline 中文</t></is></c></row></sheetData></worksheet>')
    result = read(xlsx)["text"]
    assert all(value in result for value in ["Results", "A1: Revenue", "B1: 42", "C1: 84", "formula: =B1*2", "Inline 中文"])
    def office_fixture(ext, parts):
        path = file(ext, b"")
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, contents in parts.items():
                archive.writestr(name, contents)
        return path

    word_namespaces = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main",
                       "http://purl.oclc.org/ooxml/wordprocessingml/main"]
    sheet_namespaces = ["http://schemas.openxmlformats.org/spreadsheetml/2006/main",
                        "http://purl.oclc.org/ooxml/spreadsheetml/main"]
    relationship_namespaces = ["http://schemas.openxmlformats.org/officeDocument/2006/relationships",
                              "http://purl.oclc.org/ooxml/officeDocument/relationships"]
    package_namespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    for namespace in word_namespaces:
        for prefix in ("w:", "renamed:", ""):
            declaration = f'xmlns:{prefix[:-1]}' if prefix else "xmlns"
            xml = (f'<{prefix}document {declaration}="{namespace}" xmlns:foreign="urn:foreign">'
                   f'<{prefix}body><{prefix}p><{prefix}r><{prefix}t>Word example 中文</{prefix}t>'
                   f'<foreign:t>FOREIGN TEXT</foreign:t></{prefix}r></{prefix}p>'
                   f'<{prefix}tbl><{prefix}tr><{prefix}tc><{prefix}p><{prefix}r>'
                   f'<{prefix}t>Table cell</{prefix}t></{prefix}r></{prefix}p></{prefix}tc>'
                   f'</{prefix}tr></{prefix}tbl></{prefix}body></{prefix}document>')
            assert read(office_fixture("docx", {"word/document.xml": xml}))["text"] == parsed["text"]
        blank = f'<document xmlns="{namespace}"><body/></document>'
        assert "error" not in read(office_fixture("docx", {"word/document.xml": blank}))
    breaks = ('<document xmlns="' + word_namespaces[0] + '"><body><p><r>'
              '<t>A</t><tab/><t>B</t><br/><t>C</t></r></p></body></document>')
    assert "A\tB\nC\n" in read(office_fixture("docx", {"word/document.xml": breaks}))["text"]
    for wrong_root in ('<document xmlns="urn:foreign"/>', '<document/>',
                       '<body xmlns="' + word_namespaces[0] + '"/>'):
        assert "error" in read(office_fixture("docx", {"word/document.xml": wrong_root}))

    def workbook_parts(namespace, relation_namespace, prefix):
        declaration = f'xmlns:{prefix[:-1]}' if prefix else "xmlns"
        workbook = (f'<{prefix}workbook {declaration}="{namespace}" xmlns:link="{relation_namespace}" xmlns:foreign="urn:foreign">'
                    f'<{prefix}sheets><{prefix}sheet name="Results" link:id="rId1"/>'
                    f'<{prefix}group xmlns:link="urn:rebound">'
                    f'<{prefix}sheet name="Imposter" link:id="rId1"/>'
                    f'<{prefix}sheet xmlns:alternate="{relation_namespace}" name="Nested" alternate:id="rId2"/>'
                    f'</{prefix}group><{prefix}sheet name="Restored" link:id="rId3"/>'
                    '<foreign:sheet name="Foreign element" link:id="rId1"/>'
                    f'<{prefix}sheet name="Unqualified attribute" id="rId1"/>'
                    f'<{prefix}sheet name="Foreign attribute" foreign:id="rId1"/>'
                    '<sheet xmlns="" name="Namespace-free child" link:id="rId1"/>'
                    f'</{prefix}sheets></{prefix}workbook>')
        relationships = (f'<{prefix}Relationships {declaration}="{package_namespace}">'
                         + ''.join(f'<{prefix}Relationship Id="rId{i}" Target="worksheets/sheet1.xml"/>' for i in (1, 2, 3))
                         + f'</{prefix}Relationships>')
        shared = (f'<{prefix}sst {declaration}="{namespace}" xmlns:foreign="urn:foreign">'
                  f'<{prefix}si><{prefix}r><{prefix}t>Rev</{prefix}t></{prefix}r>'
                  f'<foreign:t>FOREIGN TEXT</foreign:t><{prefix}r><{prefix}t>enue</{prefix}t>'
                  f'</{prefix}r></{prefix}si></{prefix}sst>')
        sheet = (f'<{prefix}worksheet {declaration}="{namespace}" xmlns:foreign="urn:foreign">'
                 f'<{prefix}sheetData><{prefix}row><{prefix}c r="A1" t="s"><{prefix}v>0</{prefix}v></{prefix}c>'
                 f'<{prefix}c r="B1"><{prefix}v>42</{prefix}v></{prefix}c>'
                 f'<{prefix}c r="C1"><{prefix}f>B1*2</{prefix}f><{prefix}v>84</{prefix}v></{prefix}c>'
                 f'<{prefix}c r="D1" t="inlineStr"><{prefix}is><{prefix}t>Inline 中文</{prefix}t></{prefix}is></{prefix}c>'
                 '<foreign:c r="Z1"><foreign:v>IMPOSTER CELL</foreign:v></foreign:c>'
                 '<c xmlns="" r="Z2"><v>IMPOSTER CELL</v></c>'
                 f'</{prefix}row></{prefix}sheetData></{prefix}worksheet>')
        return {"xl/workbook.xml": workbook, "xl/_rels/workbook.xml.rels": relationships,
                "xl/sharedStrings.xml": shared, "xl/worksheets/sheet1.xml": sheet}

    workbook_text = None
    for namespace, relation_namespace in zip(sheet_namespaces, relationship_namespaces):
        for prefix in ("s:", "renamed:", ""):
            parts = workbook_parts(namespace, relation_namespace, prefix)
            actual = read(office_fixture("xlsx", parts))["text"]
            assert all(value in actual for value in ("[Sheet: Results]", "[Sheet: Nested]", "[Sheet: Restored]",
                                                      "A1: Revenue", "B1: 42", "C1: 84", "formula: =B1*2", "Inline 中文"))
            assert all(value not in actual for value in ("Imposter", "Foreign element", "Foreign attribute", "Unqualified attribute", "Namespace-free child", "FOREIGN TEXT", "IMPOSTER CELL"))
            assert actual.count("[Sheet:") == 3
            if workbook_text is None:
                workbook_text = actual
            assert actual == workbook_text
    with zipfile.ZipFile(xlsx) as archive:
        legacy_parts = {name: archive.read(name).decode() for name in archive.namelist()}
    legacy_parts["xl/workbook.xml"] = legacy_parts["xl/workbook.xml"].replace(
        '</sheets>', f'<s:sheet xmlns:s="{sheet_namespaces[0]}" name="Mixed namespace" r:id="rId1"/></sheets>')
    assert read(office_fixture("xlsx", legacy_parts))["text"] == result
    # The namespace-free compatibility mode is per part, never enabled by a foreign root.
    baseline_parts = workbook_parts(sheet_namespaces[0], relationship_namespaces[0], "")
    for part, root_name, namespace in (("xl/workbook.xml", "workbook", sheet_namespaces[0]),
                                      ("xl/_rels/workbook.xml.rels", "Relationships", package_namespace),
                                      ("xl/sharedStrings.xml", "sst", sheet_namespaces[0]),
                                      ("xl/worksheets/sheet1.xml", "worksheet", sheet_namespaces[0])):
        invalid = dict(baseline_parts)
        invalid[part] = f'<{root_name} xmlns="urn:foreign"/>'
        assert "error" in read(office_fixture("xlsx", invalid))
        invalid[part] = f'<wrongRoot xmlns="{namespace}"/>'
        assert "error" in read(office_fixture("xlsx", invalid))
    empty_parts = dict(baseline_parts)
    empty_parts["xl/workbook.xml"] = f'<workbook xmlns="{sheet_namespaces[0]}"><sheets/></workbook>'
    assert "error" not in read(office_fixture("xlsx", empty_parts))
    empty_parts = dict(baseline_parts)
    empty_parts["xl/worksheets/sheet1.xml"] = f'<worksheet xmlns="{sheet_namespaces[0]}"><sheetData/></worksheet>'
    assert "error" not in read(office_fixture("xlsx", empty_parts))
    hostile = file("docx", b"")
    with zipfile.ZipFile(hostile, "w") as archive:
        archive.writestr("word/document.xml", '<!DOCTYPE x [<!ENTITY e SYSTEM="file:///etc/passwd">]><w:document xmlns:w="test"><w:t>&e;</w:t></w:document>')
    assert "error" in read(hostile)
    utf16_hostile = file("docx", b"")
    with zipfile.ZipFile(utf16_hostile, "w") as archive:
        archive.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY e "test">]><w:document xmlns:w="test"><w:t>&e;</w:t></w:document>'.encode("utf-16"))
    assert "error" in read(utf16_hostile)
    bad_shared = file("xlsx", b"")
    with zipfile.ZipFile(xlsx) as source, zipfile.ZipFile(bad_shared, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in source.namelist():
            value = source.read(name)
            if name == "xl/sharedStrings.xml": value = ('<sst><si><t>' + 'X' * 510_000 + '</t></si><si><t>Real label</t></si></sst>').encode()
            if name == "xl/worksheets/sheet1.xml": value = b'<worksheet><sheetData><row><c r="A1" t="s"><v>1</v></c></row></sheetData></worksheet>'
            archive.writestr(name, value)
    assert "error" in read(bad_shared)
    outside_scratch = root / "outside-scratch"
    outside_scratch.mkdir()
    if scratch.exists():
        import shutil
        shutil.rmtree(scratch.parent)
    scratch.parent.symlink_to(outside_scratch, target_is_directory=True)
    assert "error" in read(docx) and not list(outside_scratch.iterdir())
    scratch.parent.unlink()
    print("PASS: real DOCX/XLSX, Strict/Transitional/renamed/default namespaces, scoped attributes, empty and foreign roots, entity and size limits")

    def png(width, height, dpi):
        def chunk(kind, value):
            return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
        header = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 1, 0, 0, 0, 0))
        resolution = round(dpi / 0.0254)
        physical = chunk(b"pHYs", struct.pack(">IIB", resolution, resolution, 1))
        pixels = zlib.compress(b"\0" * (height * (1 + (width + 7) // 8)))
        return b"\x89PNG\r\n\x1a\n" + header + physical + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")

    for dpi in (72, 720):
        rejected = read(file("png", png(9000, 5000, dpi)))
        assert "40,000,000-pixel" in rejected["error"], rejected
    for dpi in (72, 720):
        result = read(file("png", png(50, 30, dpi)))
        image = result["images"][0]
        assert image["mimeType"] == "image/png"
        encoded = base64.b64decode(image["data"])
        assert struct.unpack(">II", encoded[16:24]) == (50, 30)
    assert "error" in read(file("png", b"not an image"))
    print("PASS: actual reader rejects oversized ordinary/high-DPI raster before decoding, preserves small raster pixels, malformed image denial")

    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    stream = b"BT /F1 18 Tf 20 200 Td (PDF attachment canary) Tj ET"
    objects.append(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
    pdf = bytearray(b"%PDF-1.4\n"); offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(pdf)); pdf.extend(f"{index} 0 obj\n".encode() + value + b"\nendobj\n")
    start = len(pdf)
    pdf.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]: pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF".encode())
    document = file("pdf", pdf)
    assert "PDF attachment canary" in read(document)["text"]
    page = read(document, 1)
    assert len(page["images"]) == 1 and page["images"][0]["mimeType"] == "image/png"
    page_bytes = base64.b64decode(page["images"][0]["data"])
    assert len(page_bytes) <= 5_500_000 and max(struct.unpack(">II", page_bytes[16:24])) <= 1600
    assert "error" in read(document, 2)
    print("PASS: real PDF text, page image, out-of-range page failure")

    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read_attachment", "arguments": {"path": str(text)}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_attachment", "arguments": {"path": str(foreign)}}},
    ]
    completed = subprocess.run([str(tool), "--mcp", "--root", str(note), "--scratch", str(scratch)],
        input="".join(json.dumps(frame) + "\n" for frame in frames).encode(), capture_output=True, check=True, timeout=40)
    responses = {frame["id"]: frame for frame in map(json.loads, completed.stdout.splitlines())}
    assert [x["name"] for x in responses[2]["result"]["tools"]] == ["read_attachment"]
    assert not responses[3]["result"]["isError"] and "A text attachment" in str(responses[3])
    assert responses[4]["result"]["isError"] and "OTHER NOTE CANARY" not in str(responses[4])
    print("PASS: actual MCP transport, one bounded reader, note isolation")
