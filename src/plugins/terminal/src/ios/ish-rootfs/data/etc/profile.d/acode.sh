export HOME=/home/acode
export USER=acode
export LOGNAME=acode
export PATH=/home/acode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Direct interactive `vite` runs should publish a Network URL that can be
# opened from the development machine instead of binding only guest loopback.
vite() {
	command vite --host 0.0.0.0 "$@"
}
