{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "ketch";
  version = "0.16.2";

  src = fetchFromGitHub {
    owner = "1broseidon";
    repo = "ketch";
    tag = "v${finalAttrs.version}";
    hash = "sha256-kkRscQAO29jbDAYJKN3SXDdZu9XV0D9ylC3WyqW+pTU=";
  };

  vendorHash = "sha256-Kk7fY27y1ziJEMpwRUoGfslGYYQdayLDuuRvNyfiAy8=";

  meta = {
    description = "Fast, stateless CLI for web search, code search, library docs, and scraping";
    homepage = "https://github.com/1broseidon/ketch";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ Makesesama ];
    mainProgram = "ketch";
  };
})
