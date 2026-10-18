# Source from ~/.zshrc to get Ptyxis "Command completed" notifications in zsh.
#
# VTE's vte.sh sends the "command finished" signal for zsh but never the
# "command started" one (bash gets both), so Ptyxis never notifies in zsh.
# This adds the missing signal, loading vte.sh first if it isn't loaded yet.

[[ -o interactive && -n ${VTE_VERSION-}${PTYXIS_VERSION-} ]] || return 0

if (( ! ${precmd_functions[(Ie)__vte_precmd]:-0} )); then
  for __pn_f in /etc/profile.d/vte.sh /etc/profile.d/vte-2.91.sh; do
    [[ -r $__pn_f ]] && { source $__pn_f; break; }
  done
  unset __pn_f
fi

autoload -Uz add-zsh-hook

# No vte.sh on this system: send "command finished" ourselves
if (( ! ${precmd_functions[(Ie)__vte_precmd]:-0} )); then
  __ptyxis_notify_precmd() { printf '\e]666;vte.shell.precmd!\e\\'; }
  add-zsh-hook precmd __ptyxis_notify_precmd
fi

__ptyxis_notify_preexec() { printf '\e]666;vte.shell.preexec!\e\\'; }
add-zsh-hook preexec __ptyxis_notify_preexec
