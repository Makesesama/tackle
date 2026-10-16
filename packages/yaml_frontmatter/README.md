# yaml_frontmatter

A small, dependency-free parser for the YAML front matter of Markdown files,
such as `SKILL.md` files, agent definitions, or rule files. It covers what such
files use (flat `key: value` entries, quoted scalars, booleans, flow lists,
comments, and block scalars), not full YAML.

```elixir
YamlFrontmatter.parse_document("---\nname: reviewer\n---\nPrompt.\n")
#=> {:ok, %{frontmatter: %{"name" => "reviewer"}, body: "Prompt."}}

YamlFrontmatter.parse("just some markdown")
#=> {:ok, %{}}
```

Unknown keys are kept, so callers decide what to use. A document without a
leading `---` fence has no front matter. An unterminated fence returns
`{:error, :unterminated_frontmatter}`.

```sh
mix compile --warnings-as-errors && mix test
mix format --check-formatted
```
