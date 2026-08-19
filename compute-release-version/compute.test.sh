#!/usr/bin/env bash
# compute.test.sh — fires compute.sh against a stubbed `gh`.
#
# WHY A STUB AND NOT A LIVE REPO: the bug this pins was invisible in production. `--base develop`
# was hardcoded, so on a trunk→main repo the PR list came back empty, bump was "none" and
# should-release "false" — with exit 0 and no error, forever. A test that only asserts "it ran
# successfully" would have passed the whole time. What has to be asserted is the ARGUMENT the
# action passes to `gh`, and the only way to see that is to stand in for `gh`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# --- the stub ----------------------------------------------------------------
# Records every invocation, and answers the two calls compute.sh makes.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$1" in
  api)
    # No tags: forces the "all merged PRs" range, which keeps the test focused
    # on the base-branch argument rather than on date cutoffs.
    echo ""
    ;;
  pr)
    # One merged PR carrying STUB_LABEL (semver:minor unless a test says otherwise). If the base
    # filter is wrong, the real gh would return nothing — so the stub returns this ONLY for the
    # expected base.
    if printf '%s' "$*" | grep -q -- "--base $EXPECT_BASE"; then
      printf '[{"number":1,"labels":[{"name":"%s"}],"mergedAt":"2026-07-01T00:00:00Z","title":"chore(deps): x"}]\n' "${STUB_LABEL:-semver:minor}"
    else
      echo '[]'
    fi
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run_compute() { # run_compute <expected-base> [BASE_BRANCH]
  export GH_CALLS="$TMP/calls.txt"; : >"$GH_CALLS"
  export EXPECT_BASE="$1"
  local out="$TMP/output.txt"; : >"$out"
  env PATH="$TMP/bin:$PATH" \
      CURRENT_VERSION=1.0.0 \
      GITHUB_REPOSITORY=owner/repo \
      GITHUB_OUTPUT="$out" \
      GH_TOKEN=stub \
      ${2:+BASE_BRANCH="$2"} \
      bash "$HERE/compute.sh" >/dev/null 2>&1
  cat "$out"
}

echo "compute-release-version · base-branch"

# 1 · el default NO cambia: los productos son develop→main y deben seguir igual.
out="$(run_compute develop)"
if grep -q -- "--base develop" "$TMP/calls.txt"; then
  ok "sin BASE_BRANCH usa 'develop' (los productos no se rompen)"
else
  bad "sin BASE_BRANCH usa 'develop'" "$(grep 'pr list' "$TMP/calls.txt" | head -1)"
fi

# 2 · el input manda. ESTE es el caso que no existía y hacía la action inservible
#     en trunk→main: nunca preguntaba por `main`, así que nunca veía una sola PR.
out="$(run_compute main main)"
if grep -q -- "--base main" "$TMP/calls.txt"; then
  ok "BASE_BRANCH=main pregunta por 'main'"
else
  bad "BASE_BRANCH=main pregunta por 'main'" "$(grep 'pr list' "$TMP/calls.txt" | head -1)"
fi

# 3 · y el efecto de verdad: con la base correcta, SALE un release.
#     Sin esto el test sólo probaría que se pasa una cadena, no que sirva de algo.
if grep -q '^bump=minor' <<<"$out" && grep -q '^should-release=true' <<<"$out"; then
  ok "con la base correcta hay bump (minor) y should-release=true"
else
  bad "con la base correcta hay bump" "$(tr '\n' ' ' <<<"$out")"
fi

# 4 · la regresión, escrita como tal: base equivocada => 'none' SIN error.
#     Es el modo de fallo original, y lo que lo hacía indetectable es el exit 0.
out="$(run_compute main develop)"
if grep -q '^bump=none' <<<"$out" && grep -q '^should-release=false' <<<"$out"; then
  ok "base equivocada => none/false, y en silencio (el fallo original)"
else
  bad "base equivocada => none/false" "$(tr '\n' ' ' <<<"$out")"
fi

echo
echo "compute-release-version · techo del major"

# run_major <current-version> <allow-major|""> -> imprime GITHUB_OUTPUT, deja el stderr en $TMP/err
run_major() {
  export GH_CALLS="$TMP/calls.txt"; : >"$GH_CALLS"
  export EXPECT_BASE=develop
  export STUB_LABEL=semver:major
  local out="$TMP/output.txt"; : >"$out"
  env PATH="$TMP/bin:$PATH" \
      CURRENT_VERSION="$1" \
      GITHUB_REPOSITORY=owner/repo \
      GITHUB_OUTPUT="$out" \
      GH_TOKEN=stub \
      ${2:+ALLOW_MAJOR="$2"} \
      bash "$HERE/compute.sh" >/dev/null 2>"$TMP/err"
  unset STUB_LABEL
  cat "$out"
}

# 5 · el caso que costó un 1.0.0: una PR de Renovate con semver:major, y por defecto
#     el producto NO salta de major. 0.2.0 -> 0.3.0, nunca 1.0.0.
out="$(run_major 0.2.0 "")"
if grep -q '^bump=minor' <<<"$out" && grep -q '^next-version=0.3.0' <<<"$out"; then
  ok "por defecto semver:major se capa a minor (0.2.0 -> 0.3.0, no 1.0.0)"
else
  bad "por defecto semver:major se capa" "$(tr '\n' ' ' <<<"$out")"
fi

# 6 · y lo capado se DICE, no se traga: quien pidió el major sigue visible en la salida.
if grep -q '^bump-requested=major' <<<"$out" && grep -q '^major-capped=true' <<<"$out"; then
  ok "el cap se declara (bump-requested=major, major-capped=true)"
else
  bad "el cap se declara" "$(tr '\n' ' ' <<<"$out")"
fi

# 7 · y el log nombra la PR concreta. Un cap silencioso es como se coló el primero.
if grep -q 'MAJOR CAPPED' "$TMP/err" && grep -q '#1' "$TMP/err"; then
  ok "el log avisa y nombra la PR que pidió el major"
else
  bad "el log avisa y nombra la PR" "$(tr '\n' ' ' <"$TMP/err")"
fi

# 8 · el contraste que hace válido al test 5: con el mismo input y allow-major=true,
#     SÍ sale major. Si esto no cambiara, el test 5 estaría pasando por otra razón.
out="$(run_major 0.2.0 true)"
if grep -q '^bump=major' <<<"$out" && grep -q '^next-version=1.0.0' <<<"$out" && grep -q '^major-capped=false' <<<"$out"; then
  ok "con allow-major=true el major pasa (0.2.0 -> 1.0.0), así que el cap es lo que decide"
else
  bad "con allow-major=true el major pasa" "$(tr '\n' ' ' <<<"$out")"
fi

# 9 · el cap NO toca nada por debajo de major: un minor sigue siendo minor.
out="$(run_compute develop)"
if grep -q '^bump=minor' <<<"$out" && grep -q '^major-capped=false' <<<"$out"; then
  ok "el cap no toca los bumps por debajo de major"
else
  bad "el cap no toca los bumps por debajo de major" "$(tr '\n' ' ' <<<"$out")"
fi

printf '\n%s pasan, %s fallan\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
