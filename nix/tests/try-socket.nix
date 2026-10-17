{ runCommandCC }:

# `try-socket FAMILY` (unix, inet, netlink) creates one socket of that
# address family and exits 0 on success, 2 when the family is refused with
# EAFNOSUPPORT (a seccomp filter or RestrictAddressFamilies=), 1 otherwise.
# For tests of the review jail's socket filter.
runCommandCC "try-socket"
  {
    meta.mainProgram = "try-socket";
    source = ''
      #include <errno.h>
      #include <linux/netlink.h>
      #include <stdio.h>
      #include <string.h>
      #include <sys/socket.h>

      int main(int argc, char **argv) {
        int s;
        if (argc != 2) return 1;
        if (!strcmp(argv[1], "unix")) s = socket(AF_UNIX, SOCK_STREAM, 0);
        else if (!strcmp(argv[1], "inet")) s = socket(AF_INET, SOCK_STREAM, 0);
        else if (!strcmp(argv[1], "netlink")) s = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
        else return 1;
        if (s >= 0) return 0;
        int error = errno;  /* perror may change errno */
        perror(argv[1]);
        return error == EAFNOSUPPORT ? 2 : 1;
      }
    '';
    passAsFile = [ "source" ];
  }
  ''
    mkdir -p "$out/bin"
    cp "$sourcePath" try-socket.c
    $CC -O2 -Wall -Werror try-socket.c -o "$out/bin/try-socket"
  ''
