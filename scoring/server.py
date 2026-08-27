"""Local MCP server for resume scoring and cover-letter rendering.

TrueForge's own sandbox (bwrap + local network relay) cannot complete its
one-time bootstrap dependency install in this environment — reproduced
independent of pip vs curl, independent of where `socat` is installed, and
across a fresh process restart (see NOTES.md in this directory for the full
trace). Rather than run agent-written scoring code inside that broken
sandbox, this exposes the scoring/rendering step as fixed local tools: the
agent still does the judgment work (reading job descriptions, writing the
tailored letter text), this just does the mechanical parts — PDF text
extraction, keyword-overlap ranking, PDF rendering.

Requires: nothing (no external API keys).
"""

import base64
import io
import re
from pathlib import Path

from fpdf import FPDF
from mcp.server.mcpserver import MCPServer
from pypdf import PdfReader

OUTPUT_DIR = Path(__file__).parent.parent / "output" / "cover_letters"

server = MCPServer("scoring")

_STOPWORDS = {
    "the", "and", "for", "with", "you", "your", "our", "are", "will",
    "have", "has", "this", "that", "from", "who", "job", "work", "role",
    "team", "years", "experience", "we", "in", "to", "of", "a", "an",
    "on", "at", "is", "as", "be", "or", "it", "by", "not",
}


def _tokenize(text: str) -> set[str]:
    words = re.findall(r"[a-zA-Z][a-zA-Z0-9+#.]{2,}", text.lower())
    return {w for w in words if w not in _STOPWORDS}


@server.tool()
def parse_resume(file_base64: str, filename: str) -> str:
    """Decode a resume file (PDF or plain text, base64-encoded) and return its text."""
    raw = base64.b64decode(file_base64)
    if filename.lower().endswith(".pdf"):
        reader = PdfReader(io.BytesIO(raw))
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    return raw.decode("utf-8", errors="replace")


@server.tool()
def score_jobs(resume_text: str, jobs: list[dict]) -> list[dict]:
    """Rank job listings by keyword overlap with the resume; drops duplicates.

    Each job dict should have at least "company" and "title"; "description"
    is used for scoring if present. Duplicates are jobs sharing the same
    (company, title) pair, case-insensitive — only the first is kept.
    """
    resume_words = _tokenize(resume_text)

    seen = set()
    deduped = []
    for job in jobs:
        key = (job.get("company", "").strip().lower(), job.get("title", "").strip().lower())
        if key in seen:
            continue
        seen.add(key)
        deduped.append(job)

    scored = []
    for job in deduped:
        job_text = f"{job.get('title', '')} {job.get('description', '')}"
        job_words = _tokenize(job_text)
        overlap = resume_words & job_words
        union = resume_words | job_words
        score = len(overlap) / len(union) if union else 0.0
        scored.append({
            **job,
            "score": round(score, 4),
            "matched_keywords": sorted(overlap, key=len, reverse=True)[:8],
        })

    scored.sort(key=lambda j: j["score"], reverse=True)
    return scored


# fpdf's core Helvetica font is Latin-1 only; LLM-written text routinely
# uses smart punctuation outside that range. Normalize to ASCII equivalents
# rather than bundling a Unicode font just for this.
_ASCII_EQUIVALENTS = str.maketrans({
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-", "…": "...",
})


def _sanitize_for_pdf(text: str) -> str:
    text = text.translate(_ASCII_EQUIVALENTS)
    return text.encode("latin-1", errors="replace").decode("latin-1")


@server.tool()
def render_cover_letter(letter_text: str, applicant_name: str, company: str, role: str) -> str:
    """Render tailored cover letter text as a one-page PDF. Returns the saved file path."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^a-zA-Z0-9]+", "_", f"{company}_{role}").strip("_").lower()
    out_path = OUTPUT_DIR / f"{safe}.pdf"

    pdf = FPDF(format="letter")
    pdf.add_page()
    pdf.set_margins(25, 25, 25)
    pdf.set_font("Helvetica", size=11)
    pdf.multi_cell(0, 6, _sanitize_for_pdf(applicant_name))
    pdf.ln(4)
    pdf.multi_cell(0, 6, _sanitize_for_pdf(f"Re: {role} at {company}"))
    pdf.ln(6)
    pdf.multi_cell(0, 6, _sanitize_for_pdf(letter_text))
    pdf.output(str(out_path))

    return str(out_path)


if __name__ == "__main__":
    server.run(transport="streamable-http", host="127.0.0.1", port=8792)
