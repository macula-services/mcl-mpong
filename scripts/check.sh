#!/usr/bin/env bash
# Run what CI runs (lint.yml): compile under warnings_as_errors, eunit, elvis.
# Pins OTP 28.4.3 first on PATH, the same release the Containerfile and CI use,
# and prints it, so a green run says which release it was green on.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/share/mise/installs/erlang/28.4.3/bin:$PATH"
echo "OTP $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
rebar3 compile
rebar3 eunit
rebar3 lint
