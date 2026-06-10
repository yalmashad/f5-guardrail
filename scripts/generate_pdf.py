#!/usr/bin/env python3
"""Generate a readable PDF from the GitHub runbook Markdown.

This intentionally supports the Markdown subset used by README.md. It avoids
network access and external converters so the artifact can be reproduced from
the local workspace runtime.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[1]


def inline_markup(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<font name='Courier' color='#0b3a63'>\1</font>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"<link href='\2' color='#1f5ea8'>\1</link>", text)
    text = re.sub(r"&lt;(https?://[^&]+)&gt;", r"<link href='\1' color='#1f5ea8'>\1</link>", text)
    return text


def build_styles():
    base = getSampleStyleSheet()
    base.add(
        ParagraphStyle(
            name="TitleCustom",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=22,
            leading=27,
            textColor=colors.HexColor("#0f2f57"),
            spaceAfter=14,
            alignment=TA_LEFT,
        )
    )
    base.add(
        ParagraphStyle(
            name="Heading2Custom",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=14,
            leading=18,
            textColor=colors.HexColor("#173f70"),
            spaceBefore=12,
            spaceAfter=6,
        )
    )
    base.add(
        ParagraphStyle(
            name="Heading3Custom",
            parent=base["Heading3"],
            fontName="Helvetica-Bold",
            fontSize=11.5,
            leading=15,
            textColor=colors.HexColor("#24517f"),
            spaceBefore=9,
            spaceAfter=4,
        )
    )
    base.add(
        ParagraphStyle(
            name="BodyCustom",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.5,
            leading=12.8,
            textColor=colors.HexColor("#172033"),
            spaceAfter=6,
        )
    )
    base.add(
        ParagraphStyle(
            name="CodeCustom",
            parent=base["Code"],
            fontName="Courier",
            fontSize=7.2,
            leading=9,
            leftIndent=0,
            rightIndent=0,
            spaceBefore=4,
            spaceAfter=7,
            backColor=colors.HexColor("#f4f7fb"),
            borderColor=colors.HexColor("#d8e1ec"),
            borderWidth=0.5,
            borderPadding=5,
        )
    )
    base.add(
        ParagraphStyle(
            name="QuoteCustom",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.3,
            leading=12.5,
            leftIndent=10,
            borderColor=colors.HexColor("#356eb8"),
            borderWidth=0,
            borderPadding=6,
            backColor=colors.HexColor("#f5f8fc"),
            textColor=colors.HexColor("#28364f"),
            spaceAfter=7,
        )
    )
    return base


def parse_table(lines: list[str], start: int, styles) -> tuple[Table, int]:
    rows: list[list[str]] = []
    i = start
    while i < len(lines) and lines[i].strip().startswith("|"):
        line = lines[i].strip()
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not all(set(c) <= {"-", ":", " "} for c in cells):
            rows.append(cells)
        i += 1

    data = [[Paragraph(inline_markup(cell), styles["BodyCustom"]) for cell in row] for row in rows]
    table = Table(data, repeatRows=1, hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e9f0f8")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#0f2f57")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#c9d5e5")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table, i


def flush_paragraph(story, buf: list[str], styles) -> None:
    if not buf:
        return
    story.append(Paragraph(inline_markup(" ".join(buf)), styles["BodyCustom"]))
    buf.clear()


def flush_bullets(story, bullets: list[str], styles) -> None:
    if not bullets:
        return
    items = [ListItem(Paragraph(inline_markup(item), styles["BodyCustom"])) for item in bullets]
    story.append(ListFlowable(items, bulletType="bullet", leftIndent=16, bulletFontSize=7))
    bullets.clear()


def markdown_to_story(markdown: str, styles):
    story = []
    lines = markdown.splitlines()
    para: list[str] = []
    bullets: list[str] = []
    i = 0
    in_code = False
    code_lines: list[str] = []

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("```"):
            if in_code:
                flush_paragraph(story, para, styles)
                flush_bullets(story, bullets, styles)
                story.append(Preformatted("\n".join(code_lines), styles["CodeCustom"], maxLineLength=96))
                code_lines = []
                in_code = False
            else:
                flush_paragraph(story, para, styles)
                flush_bullets(story, bullets, styles)
                in_code = True
            i += 1
            continue

        if in_code:
            code_lines.append(line)
            i += 1
            continue

        if stripped.startswith("|") and i + 1 < len(lines) and lines[i + 1].strip().startswith("|"):
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            table, i = parse_table(lines, i, styles)
            story.append(table)
            story.append(Spacer(1, 5))
            continue

        if not stripped:
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            i += 1
            continue

        if stripped == "---":
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            story.append(Spacer(1, 8))
            i += 1
            continue

        if stripped.startswith("# "):
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            story.append(Paragraph(inline_markup(stripped[2:]), styles["TitleCustom"]))
            i += 1
            continue

        if stripped.startswith("## "):
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            story.append(Paragraph(inline_markup(stripped[3:]), styles["Heading2Custom"]))
            i += 1
            continue

        if stripped.startswith("### "):
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            story.append(Paragraph(inline_markup(stripped[4:]), styles["Heading3Custom"]))
            i += 1
            continue

        if stripped.startswith(">"):
            flush_paragraph(story, para, styles)
            flush_bullets(story, bullets, styles)
            story.append(Paragraph(inline_markup(stripped.lstrip("> ")), styles["QuoteCustom"]))
            i += 1
            continue

        if stripped.startswith("- "):
            flush_paragraph(story, para, styles)
            bullets.append(stripped[2:])
            i += 1
            continue

        para.append(stripped)
        i += 1

    flush_paragraph(story, para, styles)
    flush_bullets(story, bullets, styles)
    return story


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.HexColor("#5b677a"))
    canvas.drawString(inch * 0.72, 0.45 * inch, "F5 AI Security Guardrails on Amazon EKS")
    canvas.drawRightString(letter[0] - inch * 0.72, 0.45 * inch, f"Page {doc.page}")
    canvas.restoreState()


def main() -> int:
    source = ROOT / "README.md"
    output = ROOT / "docs" / "f5-ai-security-guardrails-eks-poc-runbook.pdf"
    output.parent.mkdir(parents=True, exist_ok=True)

    styles = build_styles()
    story = markdown_to_story(source.read_text(), styles)

    doc = SimpleDocTemplate(
        str(output),
        pagesize=letter,
        rightMargin=0.72 * inch,
        leftMargin=0.72 * inch,
        topMargin=0.72 * inch,
        bottomMargin=0.78 * inch,
        title="F5 AI Security Guardrails on Amazon EKS",
        author="Yasser Elmashad",
        subject="Single-node EKS PoC deployment runbook",
    )
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
