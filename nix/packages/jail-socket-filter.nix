{
  runCommandCC,
  libseccomp,
}:

# A compiled seccomp filter for exec-jail.nix's `restrictSockets`: only Unix,
# IPv4, and IPv6 sockets in the jail (see jail-socket-filter.c). Built for
# the host it runs on, so the filter is for that architecture.
runCommandCC "tackle-jail-socket-filter.bpf" { buildInputs = [ libseccomp ]; } ''
  $CC -O2 -Wall -Werror ${./jail-socket-filter.c} -lseccomp -o generate
  ./generate "$out"
''
