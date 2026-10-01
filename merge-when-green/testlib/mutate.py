"""Mutation runner: every mutant is a plausible "simplification" that reopens a hole; the suite must
kill each one (fail). A mutant whose text no longer matches the source is itself a failure: the
suite would be guarding a line that moved.

    python3 mutate.py <test-module> <mutants.json>
mutants.json: [{"file": "risk-class/risk_class.py", "old": "...", "new": "...", "why": "..."}]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DIRS = ("risk-class", "merge-when-green", "develop-health", "revert-merge", "pr-body", "check-pr-tldr")


def main(test, mutants_file):
    mutants = json.load(open(mutants_file, encoding="utf-8"))
    ok = bad = 0
    for m in mutants:
        tmp = tempfile.mkdtemp(prefix="mwg-mut-")
        try:
            for d in DIRS:
                if os.path.isdir(os.path.join(ROOT, d)):
                    shutil.copytree(os.path.join(ROOT, d), os.path.join(tmp, d))
            path = os.path.join(tmp, m["file"])
            src = open(path, encoding="utf-8").read()
            if m["old"] not in src:
                print("  FAIL mutant «%s»: its text no longer matches %s" % (m["why"], m["file"]))
                bad += 1
                continue
            open(path, "w", encoding="utf-8").write(src.replace(m["old"], m["new"], 1))
            env = dict(os.environ, SUT_ROOT=tmp, FAIL_FAST="1")
            p = subprocess.run([sys.executable, os.path.join(ROOT, test)], env=env, capture_output=True, text=True,
                               timeout=600)
            if p.returncode != 0:
                ok += 1
                print("  ok   mutant «%s» dies" % m["why"])
            else:
                bad += 1
                print("  FAIL mutant «%s» SURVIVES: the suite does not notice" % m["why"])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("mutants: %d killed, %d survived/stale" % (ok, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
