#!/usr/bin/env bash
# Warm the Hex user cache (HEX_HOME, default ~/.hex) to the FULL closure of a
# lockfile: registry entry in cache.ets AND package tarball in packages/ for
# every :hex entry in the lock.
#
# Why this exists: production.check's offline clean-room (HEX_OFFLINE=1
# deps.get in mix imp.package.clean_room's consumer and deployment VMs) reads
# BOTH pieces for every locked package. A ~/.hex restored from a CI cache is a
# function of its ANCESTRY (whichever job saved it, from whatever partial
# state it restored), not of the lock — this script makes it a deterministic
# function of the lock instead, by construction, on every run.
#
# Empirically established (2026-07-17, Hex 2.5.0 / Elixir 1.19.5 / OTP 28):
#   - `mix hex.package fetch NAME VSN` populates BOTH the registry entry and
#     the packages/ tarball for that package.
#   - When both are already cached it completes in ~0.3s per package and
#     succeeds even with HEX_OFFLINE=1 (i.e. it is served from cache: the
#     warm-path cost is VM boot, not network).
#   - `mix deps.get` alone does NOT cover the lock: optional deps that mix
#     skips (e.g. ex_aws_auth, goth, jose via req_llm) stay in mix.lock but
#     never reach ~/.hex.
#
# Usage: warm_hex_closure.sh [path/to/mix.lock]
set -euo pipefail

lock="$(cd "$(dirname "${1:-mix.lock}")" && pwd)/$(basename "${1:-mix.lock}")"
[ -f "$lock" ] || { echo "warm_hex_closure: no lockfile at $lock" >&2; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# mix.lock is an Elixir map literal of `name => {:hex, :name, "vsn", ...}`
# (plus non-hex entries we skip). Mix itself evaluates it the same way.
LOCKFILE="$lock" elixir -e '
  {lock, _} = Code.eval_file(System.fetch_env!("LOCKFILE"))
  for {_name, entry} <- lock, is_tuple(entry), elem(entry, 0) == :hex do
    IO.puts("#{elem(entry, 1)} #{elem(entry, 2)}")
  end
' | sort > "$scratch/closure"

total="$(wc -l < "$scratch/closure" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
  echo "warm_hex_closure: extracted zero hex entries from $lock — refusing to no-op silently" >&2
  exit 1
fi

echo "warm_hex_closure: ensuring registry entry + tarball for $total locked packages"
# Run fetches from the scratch dir: fetch also writes a tarball copy to cwd,
# which we discard — the point is the side effect on HEX_HOME.
while read -r name vsn; do
  (cd "$scratch" && mix hex.package fetch "$name" "$vsn" > /dev/null)
  echo "  ok $name $vsn"
done < "$scratch/closure"
echo "warm_hex_closure: closure complete ($total packages)"
