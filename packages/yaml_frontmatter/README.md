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

Lists keep the text the file has; `YamlFrontmatter.list/1` reads such a value
as a list of strings, from a flow list (`[read, "bash"]`), a block list
(`- read` lines), or comma-separated items, with quoted items unquoted and
commas inside braces kept (`lib/*.{ex,exs}`):

```elixir
YamlFrontmatter.list(~s(["read", 'bash']))
#=> {:ok, ["read", "bash"]}
```

Unknown keys are kept, so callers decide what to use. A document without a
leading `---` fence has no front matter. An unterminated fence returns
`{:error, :unterminated_frontmatter}`.

```sh
mix compile --warnings-as-errors && mix test
mix format --check-formatted
```
