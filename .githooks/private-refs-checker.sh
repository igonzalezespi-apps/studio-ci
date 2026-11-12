# Sourced by pre-commit, commit-msg and pre-push (not a hook itself: git only runs files named
# after a hook). Sets PRIVATE_REFS_CHECKER to the private-reference checker, or leaves it empty.
#
# The denylist is PRIVATE, so this public repo never carries it; the checker lives on the
# maintainer's machine. Lookup order:
#   1. /opt/claude-gestionado/guarda/check-private-refs.sh  (fixed, root-owned, list next to it)
#   2. $HOME/projects/studio/security/check-private-refs.sh (fallback)
# If neither exists:
#   - origin belongs to the owner's organization -> FAIL CLOSED: this is the maintainer's own
#     clone, and a missing checker means nothing would stop a private name from going public.
#   - anything else (a fork, a third-party clone) -> no-op, as before.

PRIVATE_REFS_CHECKER=""
for _candidate in \
  /opt/claude-gestionado/guarda/check-private-refs.sh \
  "$HOME/projects/studio/security/check-private-refs.sh"; do
  if [ -x "$_candidate" ]; then
    PRIVATE_REFS_CHECKER="$_candidate"
    break
  fi
done

if [ -z "$PRIVATE_REFS_CHECKER" ]; then
  _origin=$(git remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  case "$_origin" in
    *github.com[:/]igonzalezespi-apps/*)
      echo "private-refs: checker not found, refusing to continue (fail closed)." >&2
      echo "  Looked for /opt/claude-gestionado/guarda/check-private-refs.sh" >&2
      echo "  and \$HOME/projects/studio/security/check-private-refs.sh." >&2
      echo "  This clone's origin is the owner's organization, so the public-repo rule" >&2
      echo "  (never name a private project) must be checked here. Install the checker and retry." >&2
      exit 1
      ;;
  esac
fi
