#!/bin/sh
set -u

usage() {
	cat <<'EOF'
Usage: acode <command> [arguments]

Commands:
  open <file|folder>...            Open paths in Acode
  plugins list                    List installed plugins
  plugins install <id|url>        Install a plugin
  plugins uninstall <id>          Uninstall a plugin
  plugins enable|disable <id>     Change plugin state
  settings list                   Print all settings
  settings get <key>              Read a dotted setting key
  settings set <key> <value>      Set JSON or text value
  settings open                   Open settings.json in Acode
  command <id> [args...]          Run an Acode command
  version                         Print the Acode version
  info                            Print environment information
  reload                          Reload Acode
EOF
}

request() {
	if ! command -v base64 >/dev/null 2>&1; then
		echo "acode: base64 is required by the terminal bridge" >&2
		return 127
	fi

	request_id="$$-$(date +%s 2>/dev/null || echo 0)"
	payload=$(
		for value in "$@"; do
			printf '%s\n' "$value"
		done | base64 | tr -d '\r\n'
	)
	old_stty=$(stty -g 2>/dev/null || true)
	[ -n "$old_stty" ] && stty -echo 2>/dev/null || true
	printf '\033]7777;request;%s;%s\a' "$request_id" "$payload"

	prefix="__ACODE_RESPONSE_${request_id};"
	response=
	while IFS= read -r line; do
		case "$line" in
			"$prefix"*) response=$line; break ;;
		esac
	done
	[ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null || true

	if [ -z "$response" ]; then
		echo "acode: Acode closed the CLI request before replying" >&2
		return 1
	fi

	result=${response#"$prefix"}
	status=${result%%;*}
	encoded=${result#*;}
	if [ "$status" = 0 ]; then
		printf '%s' "$encoded" | base64 -d
		printf '\n'
	else
		printf '%s' "$encoded" | base64 -d >&2
		printf '\n' >&2
		return 1
	fi
}

command_name=${1:-help}
[ $# -gt 0 ] && shift

case "$command_name" in
	help|-h|--help)
		usage
		;;
	open)
		[ $# -gt 0 ] || set -- .
		for path in "$@"; do
			if command -v realpath >/dev/null 2>&1; then
				absolute=$(realpath -- "$path" 2>/dev/null || true)
			else
				absolute=
			fi
			[ -n "$absolute" ] || absolute=$(
				cd "$(dirname "$path")" 2>/dev/null &&
					printf '%s/%s' "$PWD" "$(basename "$path")"
			)
			[ -e "$absolute" ] || {
				echo "acode: path does not exist: $path" >&2
				exit 1
			}
			type=file
			[ -d "$absolute" ] && type=folder
			request open "$type" "$absolute" || exit $?
		done
		;;
	plugin|plugins|settings|command)
		request "$command_name" "$@"
		;;
	version|info|reload)
		request "$command_name"
		;;
	*)
		echo "acode: unknown command: $command_name" >&2
		usage >&2
		exit 64
		;;
esac
