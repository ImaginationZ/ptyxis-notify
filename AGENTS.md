# AGENTS.md

Guide for coding agents and contributors working on ptyxis-notify: how it
works, how to test it safely, and what to do when a Ptyxis or VTE update
breaks it. User-facing docs are in [README.md](README.md).

## What this project is

- `ptyxis-notify`: the whole tool, one POSIX `sh` script. It writes two VTE
  escape sequences to the current Ptyxis tab's pseudo-terminal, which makes
  Ptyxis show its built-in "Command completed" notification. Clicking it
  focuses that tab.
- `shell/ptyxis-notify.zsh`: zsh hooks that send the "command started"
  signal VTE's `vte.sh` omits for zsh. `ptyxis-notify.plugin.zsh` is the
  plugin-manager entry point and only sources it.
- `examples/`: copy-paste configs for Claude Code, Codex CLI, Aider and
  Gemini CLI. Each is mirrored in a README section, so update both.
- `tests/run.sh`: the test suite. `.github/workflows/ci.yml` runs shellcheck,
  `zsh -n` and the tests.

The two sequences are defined in three places that must stay in sync: the
`preexec=`/`precmd=` variables in `ptyxis-notify`, the `printf`s in
`shell/ptyxis-notify.zsh`, and `pre=`/`post=` in `tests/run.sh`.

## The upstream contract (what can break)

Nothing here is a documented Ptyxis API. The tool relies on the behavior
below. The latest versions it was checked against are recorded here, so
update this line whenever you re-verify:

- **Tested end to end:** Ptyxis 48.5 / VTE 0.80.1 (Debian).
- **Checked in source only:** Ptyxis 50.1.

Source of truth: `src/ptyxis-tab-notify.h` in
[chergert/ptyxis](https://gitlab.gnome.org/chergert/ptyxis)
([48.5](https://gitlab.gnome.org/chergert/ptyxis/-/blob/48.5/src/ptyxis-tab-notify.h),
[50.1](https://gitlab.gnome.org/chergert/ptyxis/-/blob/50.1/src/ptyxis-tab-notify.h)).

1. VTE parses `ESC ] 666 ; vte.shell.preexec ! ESC \` and
   `ESC ] 666 ; vte.shell.precmd ! ESC \` (OSC 666 "termprop" signals). It
   emits `termprop-changed::vte.shell.preexec` / `::vte.shell.precmd`, and
   Ptyxis turns these into its `shell-preexec` / `shell-precmd` signals.
2. On **preexec**, Ptyxis records the start time and asynchronously polls
   its agent for the tab's foreground command line, storing it in
   `current_cmdline`.
3. On **precmd**, if `current_cmdline` is set:
   - **window not active:** sends a `GNotification` ("Command completed",
     body = command line), keyed by the tab UUID, with default action
     `app.focus-tab-by-uuid`;
   - **window active, another tab selected:** only marks that tab
     needs-attention;
   - **that tab selected:** nothing.
4. If precmd arrives before the poll in step 2 finishes, there is no
   notification. That is why `notify` sleeps `PTYXIS_NOTIFY_DELAY` (0.5 s)
   between the two signals.
5. Since Ptyxis 50, precmd is also ignored unless at least 250 ms
   (`TIME_WATERMARK_MSEC`) have passed since preexec. Keep the default delay
   well above that.
6. The notification is withdrawn when the tab gains focus.

Hooks (Claude Code, Codex, ...) run without a controlling terminal, so the
script finds the tab's `/dev/pts/N` from its own stdio, or else by walking
parent processes through `/proc/PID/stat` (ppid and `tty_nr`; no `ps`,
because busybox's lacks `-p`).

## Rules

- **Never write escape sequences to a real terminal while developing.**
  Don't run `ptyxis-notify` bare in the session you're working in. Writing
  into a terminal that a TUI (such as a coding agent) is drawing in can
  corrupt its state. Set `PTYXIS_NOTIFY_TTY` to a file, as the tests do, or
  use the private pty from `script`. In real use this risk is accepted: the
  write is a single ~25-byte write, made while the agent is idle or waiting.
  During development there is no reason to take it.
- POSIX `sh` only (it must run under dash and busybox), no dependencies
  beyond `cat`, `readlink`, `sleep` and Linux `/proc`. Keep it a single file
  that people can `curl` into `~/.local/bin`.
- Never fail the caller. Exit 0 when there's no terminal or the write fails.
  A non-zero exit shows errors in agent UIs, and exit 2 from a Claude Code
  Stop hook makes Claude keep working instead of stopping. Only usage errors
  exit 2, apart from `run`, which exits with the wrapped command's status.
- Stay silent outside VTE (`VTE_VERSION` / `PTYXIS_VERSION` unset) unless
  `PTYXIS_NOTIFY_FORCE=1`.
- `notify` must keep ignoring extra arguments: Codex passes JSON as an argv.
- `run` re-raises a signal only when the wrapper itself received Ctrl-C
  (INT/QUIT). An exit status above 128 alone is just a status.
- Keep the docs honest: mark untested integrations as "untested".

## Testing

```sh
sh tests/run.sh                   # all available shells (sh dash bash busybox)
SHELLS=dash sh tests/run.sh       # one shell
shellcheck -s sh ptyxis-notify tests/run.sh
for f in shell/ptyxis-notify.zsh ptyxis-notify.plugin.zsh; do zsh -n "$f"; done
```

`zsh -n a b` only checks `a`, hence the loop.

The tests cover:
- the bytes written by each command, and argument handling;
- exit-status passthrough, including statuses above 128 that must not hang
  or crash the wrapper;
- Ctrl-C reaching the whole process group (`setsid`, with python3 checking
  death by signal);
- silence outside VTE, and unwritable terminals;
- the `/proc` parent walk, with the script `setsid`'d inside a `script`
  pty so it has no controlling terminal;
- the zsh hooks with an empty zshrc.

CI has no `vte.sh`, so it covers the snippet's fallback precmd; a desktop
with `vte.sh` covers the other branch. When adding a test, check that it
fails when the code it guards is broken.

**End-to-end (needs a human; it can't be automated).** Ask the user to:

1. Open a new, plain Ptyxis tab and run `sleep 8; ptyxis-notify`.
2. Switch to another app right away. Another Ptyxis tab isn't enough,
   because popups need the window unfocused.
3. Confirm that "Command completed" appears and that clicking it focuses
   that tab.
4. For the tab-switching part, start the command, switch to *another*
   Ptyxis tab, then to another app. Clicking should land on the first tab.

## When it breaks after a Ptyxis/VTE update

Find out which layer failed before changing code. Ask the user to run the
steps that need their desktop.

1. **Desktop settings:** Settings → Notifications → Ptyxis is on, and Do Not
   Disturb is off.
2. **Control experiment (no ptyxis-notify involved):** in a new tab run
   `bash --norc`, then `. /etc/profile.d/vte.sh` (or `vte-2.91.sh`), then
   `sleep 5`, and switch apps. If that doesn't notify either, Ptyxis or VTE
   changed, not this script, so continue with steps 4-6.
3. **Is Ptyxis sending anything?** While reproducing, run
   `dbus-monitor --session "interface='org.gtk.Notifications'" "interface='org.freedesktop.portal.Notification'"`.
   - If a call appears, Ptyxis works and the problem is in the desktop.
   - If nothing appears, Ptyxis rejected the signals.
   - For Ptyxis's own logs, start a separate instance with
     `G_MESSAGES_DEBUG=all ptyxis -s` and reproduce inside it.
4. **Versions:** `ptyxis --version` prints the Ptyxis, GTK and VTE versions.
   For Flatpak, use `flatpak run app.devsuite.Ptyxis --version`. The
   Flatpak bundles its own VTE, under
   `/var/lib/flatpak/app/app.devsuite.Ptyxis/current/active/files/`
   (system install) or `~/.local/share/flatpak/app/...` (user install).
   Compare with the versions at the top of the contract section.
5. **What the binary listens for:**
   `strings "$(command -v ptyxis)" | grep -E 'termprop-changed::vte\.shell|Command completed|focus-tab-by-uuid'`
   should print all of them. For Flatpak, point `strings` at `files/bin/ptyxis`.
6. **What changed upstream:** compare
   `https://gitlab.gnome.org/chergert/ptyxis/-/compare/<last tested tag>...<new tag>`,
   or in a clone run
   `git diff <old> <new> -- src/ptyxis-tab-notify.h src/ptyxis-tab.c src/ptyxis-terminal.c`.
   - Look for renamed signals, new conditions (durations, settings toggles,
     focus rules), or a changed command-line poll.
   - Ptyxis's `NEWS` file summarizes each release.
   - For VTE termprop changes, see `src/vte.sh.in` and `src/vte/vteglobals.h`
     in [GNOME/vte](https://gitlab.gnome.org/GNOME/vte).
7. **Probe timing:** `PTYXIS_NOTIFY_DEBUG=1 PTYXIS_NOTIFY_DELAY=2 ptyxis-notify`
   in a plain tab. If a longer delay fixes it, the poll got slower or a new
   minimum duration was added.
8. **After fixing:** update the contract section (behavior and versions),
   the "Tested with" line in the README, and `CHANGELOG.md`.

## Watch list (upstream changes that would simplify this)

Check each item when touching the project; remove it once it's resolved.

- **Claude Code `terminalSequence`** (hook output that Claude Code writes to
  the terminal itself, race-free; see the `terminalSequence` section of
  https://code.claude.com/docs/en/hooks). Its allowlist is OSC
  0/1/2/9/99/777 and BEL. If OSC 666 is added, the Claude Code example
  could emit the sequences that way. Check first that the 250 ms rule can
  still be met, since both would arrive at once.
- **VTE `vte.sh` for zsh:** if `src/vte.sh.in` starts emitting
  `vte.shell.preexec` in its zsh branch, the zsh snippet becomes
  unnecessary (it stays harmless).
- **Ptyxis focus/notification changes:** on each new major release, read
  Ptyxis's `NEWS` for entries about notifications, tab focus or shell
  integration, and re-verify the contract.

## Releasing

Bump `VERSION` in `ptyxis-notify`, add a `CHANGELOG.md` entry dated the
release day, commit, then `git tag vX.Y.Z && git push --tags` and create a
GitHub release.
