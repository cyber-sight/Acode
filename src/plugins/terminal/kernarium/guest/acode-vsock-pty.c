/*
 * acode-vsock-pty: serves one pseudo-terminal session per stream connection.
 *
 * Runs inside the Kernarium guest. Acode's iOS host opens a vsock stream to
 * this agent's port for every terminal session; the agent forks a shell on a
 * new PTY and relays bytes until either side ends.
 *
 * Wire format, both directions: one byte frame type, a four-byte big-endian
 * payload length, then the payload.
 *
 *   host -> guest
 *     'O' open    u16 columns, u16 rows, then the command (UTF-8, may be
 *                 empty for an interactive login shell). Must come first.
 *     'D' data    bytes for the PTY
 *     'R' resize  u16 columns, u16 rows
 *     'K' kill    no payload; hangs up the session's process group
 *   guest -> host
 *     'D' data    bytes the PTY produced
 *     'X' exit    i32 status: the exit code, or 128 + signal number
 *
 * `-t PORT` listens on loopback TCP instead of vsock so the agent and the host
 * framing can be tested on any Linux machine.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/vm_sockets.h>
#endif

#define DEFAULT_VSOCK_PORT 7000U
#define MAX_PAYLOAD (1U << 20)
#define READ_CHUNK 16384

enum {
	FRAME_OPEN = 'O',
	FRAME_DATA = 'D',
	FRAME_RESIZE = 'R',
	FRAME_KILL = 'K',
	FRAME_EXIT = 'X',
};

static void log_error(const char *what)
{
	fprintf(stderr, "acode-vsock-pty: %s: %s\n", what, strerror(errno));
}

static int write_all(int fd, const void *buffer, size_t length)
{
	const unsigned char *cursor = buffer;
	while (length > 0) {
		ssize_t written = write(fd, cursor, length);
		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += written;
		length -= (size_t)written;
	}
	return 0;
}

static int read_all(int fd, void *buffer, size_t length)
{
	unsigned char *cursor = buffer;
	while (length > 0) {
		ssize_t got = read(fd, cursor, length);
		if (got < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (got == 0)
			return 0;
		cursor += got;
		length -= (size_t)got;
	}
	return 1;
}

static int send_frame(int fd, unsigned char type, const void *payload,
	uint32_t length)
{
	unsigned char header[5];
	header[0] = type;
	header[1] = (unsigned char)(length >> 24);
	header[2] = (unsigned char)(length >> 16);
	header[3] = (unsigned char)(length >> 8);
	header[4] = (unsigned char)length;
	if (write_all(fd, header, sizeof header) < 0)
		return -1;
	return length == 0 ? 0 : write_all(fd, payload, length);
}

/* Reads one frame into a freshly allocated buffer. Returns 1 for a frame, 0 at
 * a clean end of stream, -1 on error or a malformed frame. */
static int read_frame(int fd, unsigned char *type, unsigned char **payload,
	uint32_t *length)
{
	unsigned char header[5];
	int status = read_all(fd, header, sizeof header);
	if (status <= 0)
		return status;
	*type = header[0];
	*length = (uint32_t)header[1] << 24 | (uint32_t)header[2] << 16 |
		(uint32_t)header[3] << 8 | header[4];
	if (*length > MAX_PAYLOAD) {
		errno = EMSGSIZE;
		return -1;
	}
	*payload = malloc(*length + 1U);
	if (*payload == NULL)
		return -1;
	if (*length > 0 && read_all(fd, *payload, *length) <= 0) {
		free(*payload);
		*payload = NULL;
		return -1;
	}
	(*payload)[*length] = '\0';
	return 1;
}

static struct winsize window_size(const unsigned char *payload)
{
	struct winsize size;
	memset(&size, 0, sizeof size);
	size.ws_col = (unsigned short)(payload[0] << 8 | payload[1]);
	size.ws_row = (unsigned short)(payload[2] << 8 | payload[3]);
	if (size.ws_col == 0)
		size.ws_col = 80;
	if (size.ws_row == 0)
		size.ws_row = 24;
	return size;
}

static void exec_shell(const char *command)
{
	const struct passwd *user = getpwuid(getuid());
	const char *home = user != NULL && user->pw_dir[0] != '\0' ?
		user->pw_dir : "/root";
	const char *shell = user != NULL && user->pw_shell[0] != '\0' ?
		user->pw_shell : "/bin/sh";

	setenv("TERM", "xterm-256color", 1);
	setenv("HOME", home, 1);
	setenv("SHELL", shell, 1);
	if (user != NULL) {
		setenv("USER", user->pw_name, 1);
		setenv("LOGNAME", user->pw_name, 1);
	}
	if (getenv("PATH") == NULL)
		setenv("PATH",
			"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			1);
	if (chdir(home) != 0 && chdir("/") != 0)
		log_error("chdir");

	signal(SIGPIPE, SIG_DFL);
	signal(SIGCHLD, SIG_DFL);

	if (command[0] == '\0') {
		/* A leading dash makes the shell a login shell. */
		const char *base = strrchr(shell, '/');
		char argument0[256];
		snprintf(argument0, sizeof argument0, "-%s",
			base != NULL ? base + 1 : shell);
		execl(shell, argument0, (char *)NULL);
	} else {
		execl("/bin/sh", "sh", "-lc", command, (char *)NULL);
	}
	log_error("exec");
	_exit(127);
}

static int exit_status(int status)
{
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 255;
}

static void hang_up(pid_t child)
{
	if (kill(-child, SIGHUP) != 0)
		(void)kill(child, SIGHUP);
}

/* Relays one session; runs in its own process. */
static int serve(int connection)
{
	unsigned char type = 0;
	unsigned char *payload = NULL;
	uint32_t length = 0;
	if (read_frame(connection, &type, &payload, &length) <= 0)
		return 1;
	if (type != FRAME_OPEN || length < 4) {
		fprintf(stderr, "acode-vsock-pty: session did not start with open\n");
		free(payload);
		return 1;
	}
	struct winsize size = window_size(payload);
	int master = -1;
	pid_t child = forkpty(&master, NULL, NULL, &size);
	if (child < 0) {
		log_error("forkpty");
		free(payload);
		return 1;
	}
	if (child == 0) {
		close(connection);
		exec_shell((const char *)payload + 4);
	}
	free(payload);

	int status = 0;
	int child_reaped = 0;
	unsigned char *buffer = malloc(READ_CHUNK);
	if (buffer == NULL) {
		hang_up(child);
		return 1;
	}
	for (;;) {
		struct pollfd fds[2] = {
			{ .fd = connection, .events = POLLIN },
			{ .fd = master, .events = POLLIN },
		};
		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			log_error("poll");
			break;
		}
		if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
			ssize_t got = read(master, buffer, READ_CHUNK);
			if (got > 0) {
				if (send_frame(connection, FRAME_DATA, buffer,
					(uint32_t)got) < 0)
					break;
				continue;
			}
			if (got < 0 && errno == EINTR)
				continue;
			/* EIO: every slave descriptor closed; the shell is gone. */
			if (waitpid(child, &status, 0) == child)
				child_reaped = 1;
			unsigned char code[4];
			int value = child_reaped ? exit_status(status) : 255;
			code[0] = (unsigned char)((uint32_t)value >> 24);
			code[1] = (unsigned char)((uint32_t)value >> 16);
			code[2] = (unsigned char)((uint32_t)value >> 8);
			code[3] = (unsigned char)value;
			(void)send_frame(connection, FRAME_EXIT, code, sizeof code);
			break;
		}
		if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
			int result = read_frame(connection, &type, &payload, &length);
			if (result <= 0) {
				/* The host closed the stream: end the session. */
				hang_up(child);
				break;
			}
			if (type == FRAME_DATA) {
				if (write_all(master, payload, length) < 0 &&
					errno != EIO) {
					free(payload);
					break;
				}
			} else if (type == FRAME_RESIZE && length >= 4) {
				struct winsize next = window_size(payload);
				(void)ioctl(master, TIOCSWINSZ, &next);
			} else if (type == FRAME_KILL) {
				hang_up(child);
			}
			free(payload);
			payload = NULL;
		}
	}
	free(buffer);
	close(master);
	if (!child_reaped && waitpid(child, &status, WNOHANG) == 0) {
		hang_up(child);
		(void)waitpid(child, &status, 0);
	}
	close(connection);
	return 0;
}

static int listen_socket(int tcp_port, unsigned int vsock_port)
{
	int fd;
	if (tcp_port > 0) {
		fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
		if (fd < 0)
			return -1;
		int on = 1;
		(void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
		struct sockaddr_in address;
		memset(&address, 0, sizeof address);
		address.sin_family = AF_INET;
		address.sin_port = htons((uint16_t)tcp_port);
		address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0)
			goto fail;
	} else {
#ifdef AF_VSOCK
		fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
		if (fd < 0)
			return -1;
		struct sockaddr_vm address;
		memset(&address, 0, sizeof address);
		address.svm_family = AF_VSOCK;
		address.svm_port = vsock_port;
		address.svm_cid = VMADDR_CID_ANY;
		if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0)
			goto fail;
#else
		(void)vsock_port;
		errno = EAFNOSUPPORT;
		return -1;
#endif
	}
	if (listen(fd, 16) != 0)
		goto fail;
	return fd;
fail:
	{
		int saved = errno;
		close(fd);
		errno = saved;
	}
	return -1;
}

int main(int argc, char **argv)
{
	unsigned int vsock_port = DEFAULT_VSOCK_PORT;
	int tcp_port = 0;
	int option;
	while ((option = getopt(argc, argv, "p:t:")) != -1) {
		switch (option) {
		case 'p':
			vsock_port = (unsigned int)strtoul(optarg, NULL, 10);
			break;
		case 't':
			tcp_port = atoi(optarg);
			break;
		default:
			fprintf(stderr, "usage: %s [-p vsock-port] [-t tcp-port]\n",
				argv[0]);
			return 2;
		}
	}

	signal(SIGPIPE, SIG_IGN);
	/* Session processes are reaped by the kernel; each session reaps its own
	 * shell with waitpid, which SA_NOCLDWAIT in the listener does not affect
	 * once the session process resets the disposition. */
	struct sigaction ignore_children;
	memset(&ignore_children, 0, sizeof ignore_children);
	ignore_children.sa_handler = SIG_IGN;
	ignore_children.sa_flags = SA_NOCLDWAIT;
	sigaction(SIGCHLD, &ignore_children, NULL);

	int listener = listen_socket(tcp_port, vsock_port);
	if (listener < 0) {
		log_error("listen");
		return 1;
	}
	fprintf(stderr, "acode-vsock-pty: listening on %s port %u\n",
		tcp_port > 0 ? "tcp" : "vsock",
		tcp_port > 0 ? (unsigned int)tcp_port : vsock_port);

	for (;;) {
		int connection = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
		if (connection < 0) {
			if (errno == EINTR || errno == ECONNABORTED)
				continue;
			log_error("accept");
			sleep(1);
			continue;
		}
		pid_t session = fork();
		if (session == 0) {
			close(listener);
			signal(SIGCHLD, SIG_DFL);
			_exit(serve(connection));
		}
		if (session < 0)
			log_error("fork");
		close(connection);
	}
}
