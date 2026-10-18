#!/bin/sh
# Tests for ptyxis-notify. Plain POSIX sh, prints TAP-style lines.
# Never writes to a real terminal: output goes to a file or a private pty.
#
# Usage: sh tests/run.sh            (SHELLS="dash bash" to pick shells)

# shellcheck disable=SC2015,SC2086
# (ok || bad idiom; $SH may be "busybox sh")

set -u
cd "$(dirname "$0")/.." || exit 1
bin=$PWD/ptyxis-notify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pre=$(printf '\033]666;vte.shell.preexec!\033\\')
post=$(printf '\033]666;vte.shell.precmd!\033\\')
fails=0

ok()  { echo "ok - $1"; }
bad() { echo "not ok - $1"; fails=$((fails + 1)); }
eq()  {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"; printf '#   expected: %s\n#   got:      %s\n' "$2" "$3" | tr '\033' 'E'
  fi
}
out() { cat "$tmp/tty"; }

# Run the script under $SH with output captured in $tmp/tty
pn() {
  : >"$tmp/tty"
  env PTYXIS_NOTIFY_TTY="$tmp/tty" PTYXIS_NOTIFY_DELAY=0 VTE_VERSION=8000 \
    $SH "$bin" "$@"
}

for SH in ${SHELLS:-sh dash bash "busybox sh"}; do
  command -v "${SH%% *}" >/dev/null 2>&1 || continue
  echo "# shell: $SH"

  pn;                    eq "$SH: notify"              "$pre$post" "$(out)"
  pn notify '{"a":1}';   eq "$SH: notify ignores args" "$pre$post" "$(out)"
  pn '{"type":"x"}';     eq "$SH: bare event data"     "$pre$post" "$(out)"
  pn start;              eq "$SH: start"               "$pre"      "$(out)"
  pn 'done';             eq "$SH: done"                "$post"     "$(out)"

  pn run sh -c 'exit 3'; eq "$SH: run keeps status"    3           "$?"
                         eq "$SH: run signals"         "$pre$post" "$(out)"
  pn run sh -c 'kill -INT $$'
                         eq "$SH: command killed by SIGINT, wrapper not" 130 "$?"
                         eq "$SH: command killed still finishes" "$pre$post" "$(out)"
  timeout 5 env PTYXIS_NOTIFY_TTY="$tmp/tty" VTE_VERSION=8000 $SH "$bin" run sh -c 'exit 147'
                         eq "$SH: exit 147 is just a status" 147 "$?"
  pn run >/dev/null 2>&1; eq "$SH: run without command" 2          "$?"
  if setsid -w true 2>/dev/null && command -v python3 >/dev/null 2>&1; then
    # Ctrl-C reaches the whole process group; setsid keeps it away from us.
    # python3 reports death by signal as -2, which $? can't tell from exit 130
    : >"$tmp/tty"
    env PTYXIS_NOTIFY_TTY="$tmp/tty" VTE_VERSION=8000 python3 -c '
import subprocess, sys
sys.exit(0 if subprocess.run(sys.argv[1:]).returncode == -2 else 1)' \
      setsid -w $SH "$bin" run sh -c 'kill -INT 0; sleep 5'
                         eq "$SH: Ctrl-C re-raised as SIGINT" 0     "$?"
                         eq "$SH: Ctrl-C still finishes" "$pre$post" "$(out)"
  fi
  pn run -- sh -c 'exit 4'; eq "$SH: run -- CMD" 4 "$?"
  pn run exit 3 2>/dev/null; eq "$SH: run never runs builtins" 127 "$?"
                         eq "$SH: run builtin still finishes" "$pre$post" "$(out)"
  if setsid -w true 2>/dev/null && command -v python3 >/dev/null 2>&1; then
    # A Ctrl-C the command swallowed must not be re-raised when it later
    # dies of something else
    env PTYXIS_NOTIFY_TTY="$tmp/tty" VTE_VERSION=8000 python3 -c '
import subprocess, sys
sys.exit(0 if subprocess.run(sys.argv[1:]).returncode == 143 else 1)' \
      setsid -w $SH "$bin" run sh -c 'trap "" INT; kill -INT 0; kill -TERM $$' 2>/dev/null
                         eq "$SH: swallowed Ctrl-C, then TERM -> 143" 0 "$?"
  fi

  pn --bogus >/dev/null 2>&1; eq "$SH: unknown option rc" 2        "$?"
                         eq "$SH: unknown option silent" ""         "$(out)"
  pn --help | grep -q '^Usage:' && ok "$SH: --help" || bad "$SH: --help"
  pn --version | grep -q '^ptyxis-notify [0-9]' && ok "$SH: --version" || bad "$SH: --version"

  : >"$tmp/tty"
  env -u VTE_VERSION -u PTYXIS_VERSION -u PTYXIS_NOTIFY_FORCE \
    PTYXIS_NOTIFY_TTY="$tmp/tty" $SH "$bin"
  eq "$SH: silent outside VTE" "" "$(out)"

  env PTYXIS_NOTIFY_TTY="$tmp/missing/tty" VTE_VERSION=8000 PTYXIS_NOTIFY_DELAY=0 \
    $SH "$bin" 2>"$tmp/err"
  eq "$SH: unwritable tty rc" 0 "$?"
  eq "$SH: unwritable tty quiet" "" "$(cat "$tmp/err")"
done

# Parent walk: the script runs without a controlling terminal (setsid) and
# with no terminal on stdio, under a parent that has the private pty
if command -v script >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # $PN_BIN expands in the inner shell
  env -u PTYXIS_NOTIFY_TTY VTE_VERSION=8000 PTYXIS_NOTIFY_DELAY=0 PN_BIN="$bin" \
    script -qec 'setsid sh "$PN_BIN" </dev/null >/dev/null 2>&1; :' /dev/null \
    </dev/null >"$tmp/pty" 2>&1
  grep -q 'vte.shell.preexec' "$tmp/pty" && grep -q 'vte.shell.precmd' "$tmp/pty" \
    && ok "finds tty via parents" || bad "finds tty via parents"
fi

# zsh snippet: works with an empty zshrc and installs hooks exactly once
if command -v zsh >/dev/null 2>&1; then
  hooks=$(VTE_VERSION=8000 TERM=xterm-256color zsh -f -i -c '
    source shell/ptyxis-notify.zsh; source shell/ptyxis-notify.zsh
    print -r -- ${#${(M)preexec_functions:#__ptyxis_notify_preexec}} \
      ${#${(M)precmd_functions:#(__vte_precmd|__ptyxis_notify_precmd)}}' 2>&1 </dev/null)
  eq "zsh: hooks installed once" "1 1" "$hooks"
  bytes=$(VTE_VERSION=8000 zsh -f -i -c 'source shell/ptyxis-notify.zsh; __ptyxis_notify_preexec' 2>/dev/null </dev/null)
  eq "zsh: preexec bytes" "$pre" "$bytes"
  # Note: CI has no vte.sh, so it covers the fallback precmd; a desktop covers vte.sh
  inert=$(VTE_VERSION=8000 zsh -f -c 'source shell/ptyxis-notify.zsh; print -r -- ${#preexec_functions}' 2>&1)
  eq "zsh: inert in non-interactive shells" "0" "$inert"
fi

echo "# $fails failed"
[ "$fails" -eq 0 ]
