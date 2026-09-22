#!/usr/bin/env bash
set -euo pipefail

check_mix_project() {
  local project=$1
  shift

  (
    cd "$project"
    mix deps.get --check-locked
    mix compile --warnings-as-errors
    mix test

    if (($#)); then
      mix format --check-formatted "$@"
    else
      mix format --check-formatted
    fi
  )
}

package_format_args=(
  "mix.exs"
  "lib/**/*.{ex,exs}"
  "test/**/*.{ex,exs}"
)

case "${1:-}" in
  library)
    check_mix_project packages/tackle_lib "${package_format_args[@]}"
    ;;
  runtime)
    check_mix_project packages/tackle_runtime "${package_format_args[@]}"
    ;;
  provider-plugins)
    check_mix_project packages/tackle_codex "${package_format_args[@]}"
    check_mix_project packages/tackle_deepseek "${package_format_args[@]}"
    ;;
  integration-plugins)
    check_mix_project packages/tackle_anubis "${package_format_args[@]}"
    check_mix_project packages/tackle_mcp "${package_format_args[@]}"
    check_mix_project packages/tackle_phoenix "${package_format_args[@]}"
    ;;
  harness)
    check_mix_project packages/tackle
    ;;
  cli)
    check_mix_project apps/tackle_cli
    cargo test --locked --manifest-path apps/tackle_cli/native/tackle/Cargo.toml
    cargo fmt --manifest-path apps/tackle_cli/native/tackle/Cargo.toml --check
    (cd apps/tackle_cli && mix escript.build)
    ;;
  web)
    check_mix_project apps/tackle_web
    (cd apps/tackle_web && mix assets.build)
    ;;
  *)
    echo "usage: $0 {library|runtime|provider-plugins|integration-plugins|harness|cli|web}" >&2
    exit 2
    ;;
esac
