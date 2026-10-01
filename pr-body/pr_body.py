#!/usr/bin/env python3
"""pr_body.py — a deterministic pull-request body, rendered from git and three short texts.

Modes (a TL;DR only where a person decides):
  work       the normal case (an agent integrates it): NO TL;DR. "Qué y por qué" (at most 600
             characters), "Verificación" (required), "Riesgo" (riesgo:N and why, when risk-class is
             available), "Commits", "Ficheros" (diff --stat, at most 40 lines), "Merge method" (Squash).
  human      revision-humana: "## TL;DR" FIRST (the given text + `gh pr merge N --repo R --squash`
             when --pr is known), then everything of `work`.
  promotion  develop -> main: "## TL;DR" with the four release fields and
             `gh pr merge N --repo R --merge` in a bash block, then the PRs of the range
             (`git log --first-parent base..head`), Merge method = merge commit.

Two phases: render without --pr, create the PR, render again with --pr N and `gh pr edit` (that
fires `edited`, which the TL;DR check listens to). With --pr the body is also run through
check-pr-tldr (`--check`, on by default with --pr): a body this script writes either passes the
linter or the script exits 1.

    pr-body.sh --base REF [--head REF] --mode work|human|promotion [--repo-dir D]
               [--summary-file F] [--verify-file F] [--tldr-file F] [--risk-json F]
               [--repo R --pr N] [--no-check]

Exit 0 body on stdout · 1 the rendered body fails check-pr-tldr · 2 usage or git error.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY_MAX = 600
STAT_MAX = 40
METHODS = [
    ("Squash", "Squash (the convention here - the PR TITLE becomes the commit message)"),
    ("Rebase", "Rebase (only for a multi-commit PR where every commit is a valid Conventional Commit)"),
    ("Merge commit", "Merge commit (only for a stacked parent, or a promotion PR into this branch)"),
]
FIELDS = ["Qué notarán los usuarios", "Qué puede salir mal y cómo se deshace",
          "Decisiones tuyas que van dentro", "Qué NO se ha comprobado"]


class Usage(Exception):
    pass


def git(repo_dir, *args):
    p = subprocess.run(["git", "-C", repo_dir] + list(args), capture_output=True, text=True)
    if p.returncode != 0:
        raise Usage("git %s: %s" % (" ".join(args[:2]), p.stderr.strip()[:200]))
    return p.stdout


def read(path, what, required=True):
    if not path:
        if required:
            raise Usage("missing --%s-file" % what)
        return ""
    with open(path, encoding="utf-8") as fh:
        text = fh.read().strip()
    if required and not text:
        raise Usage("--%s-file is empty" % what)
    return text


def method_section(chosen):
    lines = ["## Merge method", ""]
    for name, text in METHODS:
        lines.append("- [%s] %s" % ("x" if name == chosen else " ", text))
    return "\n".join(lines)


def risk_section(risk):
    if not risk:
        return "## Riesgo\n\nSin clasificar (risk-class no disponible en este checkout)."
    lines = ["## Riesgo", "", "`%s` · revisión: %s" % (risk["label"], risk["review"])]
    for r in risk.get("reasons", [])[:8]:
        paths = ", ".join("`%s`" % p for p in r.get("paths", [])[:4])
        lines.append("- %d · %s%s" % (r["class"], r["why"], (": " + paths) if paths else ""))
    return "\n".join(lines)


def classify(repo_dir, base, head, risk_json):
    if risk_json:
        with open(risk_json, encoding="utf-8") as fh:
            return json.load(fh)
    script = os.path.join(HERE, "..", "risk-class", "risk-class.sh")
    if not os.path.isfile(script):
        return None
    p = subprocess.run(["bash", script, "--git", "--base", base, "--head", head, "--repo-dir", repo_dir, "--json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise Usage("risk-class could not classify the diff: %s" % p.stderr.strip()[:200])
    return json.loads(p.stdout)


def work_sections(repo_dir, base, head, summary, verify, risk):
    if len(summary) > SUMMARY_MAX:
        raise Usage("the summary has %d characters (at most %d): say what and why, not how" % (len(summary), SUMMARY_MAX))
    mb = git(repo_dir, "merge-base", base, head).strip()
    commits = git(repo_dir, "log", "--reverse", "--format=- %h %s", "%s..%s" % (mb, head)).strip() or "- (ninguno)"
    stat = git(repo_dir, "diff", "--stat=100", mb, head).rstrip("\n").splitlines()
    if len(stat) > STAT_MAX:
        stat = stat[:STAT_MAX - 1] + ["… %d líneas más" % (len(stat) - STAT_MAX + 1)] + stat[-1:]
    return [
        "## Qué y por qué\n\n" + summary,
        "## Verificación\n\n" + verify,
        risk_section(risk),
        "## Commits\n\n" + commits,
        "## Ficheros\n\n```\n" + "\n".join(stat or ["(sin cambios)"]) + "\n```",
    ]


def render(a):
    repo_dir = a["repo_dir"] or "."
    base, head, mode = a["base"], a["head"] or "HEAD", a["mode"]
    if not base:
        raise Usage("--base is required")
    if mode not in ("work", "human", "promotion"):
        raise Usage("--mode must be work, human or promotion")
    if bool(a["pr"]) != bool(a["repo"]):
        raise Usage("--repo and --pr go together")
    if a["pr"] and not re.fullmatch(r"[1-9][0-9]*", a["pr"]):
        raise Usage("--pr must be a number")
    parts = []
    if mode == "promotion":
        tldr = read(a["tldr_file"], "tldr")
        missing = [f for f in FIELDS if "**%s:**" % f not in tldr]
        if missing:
            raise Usage("the promotion TL;DR needs the four fields; missing: %s" % ", ".join(missing))
        cmd = ("gh pr merge %s --repo %s --merge" % (a["pr"], a["repo"])) if a["pr"] else \
            "gh pr merge <número de esta PR> --repo <owner/name> --merge"
        parts.append("## TL;DR\n\n%s\n\n**Tu «sí»** (en tu PC):\n\n```bash\n%s\n```" % (tldr, cmd))
        mb = git(repo_dir, "merge-base", base, head).strip()
        rng = git(repo_dir, "log", "--first-parent", "--reverse", "--format=%s", "%s..%s" % (mb, head)).splitlines()
        lines = []
        for subject in rng:
            m = re.search(r"\(#(\d+)\)\s*$", subject)
            lines.append("- %s%s" % (("#%s " % m.group(1)) if m else "", re.sub(r"\s*\(#\d+\)\s*$", "", subject)))
        parts.append("## PRs de esta promoción\n\n" + ("\n".join(lines) or "- (ninguna)"))
        parts.append(method_section("Merge commit"))
    else:
        summary = read(a["summary_file"], "summary")
        verify = read(a["verify_file"], "verify")
        risk = classify(repo_dir, base, head, a["risk_json"])
        if mode == "human":
            tldr = read(a["tldr_file"], "tldr")
            cmd = ("\n\n**Tu «sí»** (en tu PC):\n\n```bash\ngh pr merge %s --repo %s --squash\n```" % (a["pr"], a["repo"])
                   if a["pr"] else "")
            parts.append("## TL;DR\n\n%s%s" % (tldr, cmd))
        parts += work_sections(repo_dir, base, head, summary, verify, risk)
        parts.append(method_section("Squash"))
    return "\n\n".join(parts) + "\n"


def check(body, a):
    script = os.path.join(HERE, "..", "check-pr-tldr", "check.sh")
    fd, path = tempfile.mkstemp(suffix=".md")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    labels = "revision-humana" if a["mode"] == "human" else ""
    args = ["bash", script, "--body", path, "--pr", a["pr"], "--repo", a["repo"], "--labels", labels]
    if a["mode"] == "promotion":
        args += ["--promotion", "--base-ref", "main", "--head-ref", "develop"]
    p = subprocess.run(args, capture_output=True, text=True)
    os.unlink(path)
    return p.returncode, p.stdout + p.stderr


def main(argv):
    spec = {"base": 1, "head": 1, "mode": 1, "repo_dir": 1, "summary_file": 1, "verify_file": 1, "tldr_file": 1,
            "risk_json": 1, "repo": 1, "pr": 1, "no_check": 0, "help": 0}
    a = {k: (False if v == 0 else None) for k, v in spec.items()}
    i = 0
    try:
        while i < len(argv):
            arg = argv[i]
            if not arg.startswith("--") or arg[2:].replace("-", "_") not in spec:
                raise Usage("unknown argument %r" % arg)
            key = arg[2:].replace("-", "_")
            if spec[key] == 0:
                a[key] = True
                i += 1
                continue
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                raise Usage("%s needs a value" % arg)
            a[key] = argv[i + 1]
            i += 2
        if a["help"]:
            print(__doc__)
            return 0
        body = render(a)
    except (Usage, OSError, ValueError) as e:
        print("pr-body: %s" % e, file=sys.stderr)
        return 2
    sys.stdout.write(body)
    if a["pr"] and not a["no_check"] and a["mode"] in ("human", "promotion"):
        rc, out = check(body, a)
        if rc != 0:
            print("pr-body: the rendered body does not pass check-pr-tldr:\n%s" % out, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
