#!/usr/bin/env bash
# Which mcl_om does this tree ACTUALLY build against? Asserts the resolved
# version, from a clean resolve against hex, equals the one named.
#
# WHY: a stale rebar.lock or a _checkouts symlink makes a green gate green on
# the wrong version, and nothing in the gate's own output says so. This deletes
# both, resolves from hex, and reads the version out of the built .app, which
# is the artefact, not the constraint that asked for it.
#
#   scripts/is-mcl-om-resolved-from-hex.sh 0.26.2
set -euo pipefail
cd "$(dirname "$0")/.."
WANT="${1:?usage: $0 <mcl_om version>}"
export PATH="$HOME/.local/share/mise/installs/erlang/28.4.3/bin:$PATH"
rm -rf rebar.lock _checkouts _build/default/lib/mcl_om _build/test/lib/mcl_om _build/prod/lib/mcl_om
rebar3 get-deps >/dev/null
rebar3 compile >/dev/null
APP=_build/default/lib/mcl_om/ebin/mcl_om.app
GOT=$(erl -noshell -eval "{ok, [{application, _, P}]} = file:consult(\"$APP\"), io:format(\"~s\", [proplists:get_value(vsn, P)]), halt().")
LOCKED=$(grep -o '{<<"mcl_om">>,{pkg,<<"mcl_om">>,<<"[^"]*">>}' rebar.lock | grep -o '<<"[0-9.]*">>' | tr -d '<>"')
echo "built mcl_om ${GOT}, locked ${LOCKED}, wanted ${WANT}"
[ "$GOT" = "$WANT" ] && [ "$LOCKED" = "$WANT" ] || { echo "MISMATCH"; exit 1; }
