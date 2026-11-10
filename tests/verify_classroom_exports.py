"""Inspect artifacts emitted by the real Swift exporter, not a Python reimplementation."""
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


def main():
    root = Path(sys.argv[1])
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    for filename, image_count in [("sample-word.docx", 3), ("sample-word-text.docx", 0), ("minutes-only.docx", 2)]:
        with zipfile.ZipFile(root / filename) as archive:
            assert archive.testzip() is None, filename
            document = ET.fromstring(archive.read("word/document.xml"))
            text = "".join(document.itertext())
            assert "中文课堂" in text and "作业与提醒" in text
            assert document.find(".//w:tbl", ns) is not None, "Markdown table must become a Word table"
            images = [p for p in archive.namelist() if p.startswith("word/media/")]
            assert len(images) == image_count, (filename, images)
            relationships = ET.fromstring(archive.read("word/_rels/document.xml.rels"))
            for relationship in relationships:
                assert "word/" + relationship.attrib["Target"] in archive.namelist()
            for name in archive.namelist():
                if name.endswith((".xml", ".rels")):
                    ET.fromstring(archive.read(name))
            if filename == "sample-word.docx":
                assert text.index("第一段") < text.index("课件图 [00:12]") < text.index("第二段")
                assert text.index("怎么理解这张图") < text.index("问题 1 附图") < text.index("结合实录分析")
    for filename, expected in [("sample-markdown.zip", 3), ("minutes-only.zip", 2)]:
        with zipfile.ZipFile(root / filename) as archive:
            assert archive.testzip() is None
            md_name = next(name for name in archive.namelist() if name.endswith(".md"))
            markdown = archive.read(md_name).decode("utf-8")
            links = re.findall(r"!\[[^\]]*(?:\][^\]]*)?\]\((images/[^)]+)\)", markdown)
            # Captions contain timestamps in brackets; paths remain plain and relative.
            links = re.findall(r"\]\((images/[^)]+)\)", markdown)
            assert len(links) == expected, (filename, links)
            assert all(link in archive.namelist() for link in links)
    assert "images/" not in (root / "sample.md").read_text(encoding="utf-8")
    print("Export ZIP integrity, Word XML, tables, embedded images and ordering passed")


if __name__ == "__main__":
    main()
