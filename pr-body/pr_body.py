#!/usr/bin/env python3
"""pr_body.py — a deterministic pull-request body, rendered from git and a few short texts.

Modes:
  work       the normal case (an agent integrates it). "Qué y por qué" (at most 600 characters),
             "Verificación" (required), "Riesgo" (riesgo:N and why, when risk-class is available),
             "Commits", "Ficheros" (diff --stat, at most 40 lines), "Merge method" (Squash).
  human      revision-humana: FIRST, before any heading, the --why-file text (in plain words, why a
             person is needed) and the squash merge command of this PR in a bash block when --pr
             is known; then everything of `work`.
  promotion  develop -> main: the optional --why-file text and the merge-commit merge command of
             this PR in a bash block, then the PRs of the range (`git log --first-parent
             base..head`), Merge method = merge commit.

Two phases: render without --pr, create the PR, render again with --repo R --pr N and
`gh pr edit`, so the merge command names the PR.

    pr-body.sh --base REF [--head REF] --mode work|human|promotion [--repo-dir D]
               [--summary-file F] [--verify-file F] [--why-file F] [--risk-json F]
               [--repo R --pr N]

Exit 0 body on stdout · 2 usage or git error.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY_MAX = 600
STAT_MAX = 40
METHODS = [
    ("Squash", "Squash (the convention here - the PR TITLE becomes the commit message)"),
    ("Rebase", "Rebase (only for a multi-commit PR where every commit is a valid Conventional Commit)"),
    ("Merge commit", "Merge commit (only for a stacked parent, or a promotion PR into this branch)"),
]


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


def merge_block(why, cmd):
    """The part a person reads first: why they are needed, then the exact command."""
    block = "**Tu «sí»** (en tu PC):\n\n```bash\n%s\n```" % cmd if cmd else ""
    return "\n\n".join(p for p in (why, block) if p)


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
        cmd = ("gh pr merge %s --repo %s --merge" % (a["pr"], a["repo"])) if a["pr"] else \
            "gh pr merge <número de esta PR> --repo <owner/name> --merge"
        parts.append(merge_block(read(a["why_file"], "why", required=False), cmd))
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
            cmd = ("gh pr merge %s --repo %s --squash" % (a["pr"], a["repo"])) if a["pr"] else ""
            parts.append(merge_block(read(a["why_file"], "why"), cmd))
        parts += work_sections(repo_dir, base, head, summary, verify, risk)
        parts.append(method_section("Squash"))
    return "\n\n".join(parts) + "\n"


def main(argv):
    spec = {"base": 1, "head": 1, "mode": 1, "repo_dir": 1, "summary_file": 1, "verify_file": 1, "why_file": 1,
            "risk_json": 1, "repo": 1, "pr": 1, "help": 0}
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
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
