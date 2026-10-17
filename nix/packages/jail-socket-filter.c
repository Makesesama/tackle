/*
 * Writes a seccomp filter (classic BPF, for Bubblewrap's --add-seccomp-fd)
 * that lets socket(2) and socketpair(2) create Unix, IPv4, and IPv6 sockets
 * only; every other address family fails with EAFNOSUPPORT, as systemd's
 * RestrictAddressFamilies= does. Everything else is allowed.
 *
 * Usage: jail-socket-filter OUTPUT
 */
#include <errno.h>
#include <fcntl.h>
#include <seccomp.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

static int deny_other_families(scmp_filter_ctx ctx, int syscall) {
  const uint32_t deny = SCMP_ACT_ERRNO(EAFNOSUPPORT);
  int rc = 0;

  /* AF_UNSPEC (0), then everything between AF_INET (2) and AF_INET6 (10),
   * then everything above, including values with high bits set. */
  rc |= seccomp_rule_add(ctx, deny, syscall, 1, SCMP_A0(SCMP_CMP_EQ, AF_UNSPEC));
  for (int family = AF_INET + 1; family < AF_INET6; family++)
    rc |= seccomp_rule_add(ctx, deny, syscall, 1, SCMP_A0(SCMP_CMP_EQ, family));
  rc |= seccomp_rule_add(ctx, deny, syscall, 1, SCMP_A0(SCMP_CMP_GT, AF_INET6));
  return rc;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s OUTPUT\n", argv[0]);
    return 2;
  }

  scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
  if (ctx == NULL) return 1;

  int rc = deny_other_families(ctx, SCMP_SYS(socket));
  rc |= deny_other_families(ctx, SCMP_SYS(socketpair));

  int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || rc != 0 || seccomp_export_bpf(ctx, fd) != 0 || close(fd) != 0) {
    fprintf(stderr, "jail-socket-filter: could not write the filter\n");
    return 1;
  }

  seccomp_release(ctx);
  return 0;
}
