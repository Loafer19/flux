# Prefer ~/.local/bin over /usr.
# Omarchy's default bash envs append ~/.local/bin, so a package in /usr/bin
# would otherwise win. Sourced from ~/.bashrc by `make install-local`.
_flux_lb="${HOME}/.local/bin"
case ":${PATH}:" in
*":${_flux_lb}:"*)
	PATH=$(printf '%s' "$PATH" | awk -v p="$_flux_lb" -F: '{
		o = ""
		for (i = 1; i <= NF; i++) if ($i != "" && $i != p) o = o (o ? ":" : "") $i
		print o
	}')
	;;
esac
export PATH="${_flux_lb}${PATH:+:$PATH}"
unset _flux_lb
