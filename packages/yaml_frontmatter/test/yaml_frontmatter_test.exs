defmodule YamlFrontmatterTest do
  use ExUnit.Case, async: true

  doctest YamlFrontmatter

  describe "parse/1 and parse_document/1" do
    test "parses a complete document and retains its Markdown body" do
      assert {:ok, %{frontmatter: frontmatter, body: "Agent prompt."}} =
               YamlFrontmatter.parse_document(
                 "---\r\nname: reviewer\r\n---\r\n\r\nAgent prompt.\r\n"
               )

      assert frontmatter == %{"name" => "reviewer"}
    end

    test "returns an empty map without a fence" do
      assert {:ok, %{}} = YamlFrontmatter.parse("just some markdown")
    end

    test "returns an error for an unterminated fence" do
      assert {:error, :unterminated_frontmatter} = YamlFrontmatter.parse("---\nname: x\n")
    end

    test "parses quoted and boolean scalars" do
      assert {:ok, frontmatter} =
               YamlFrontmatter.parse("---\ndescription: \"Quoted: value\"\nflag: true\n---\n")

      assert frontmatter["description"] == "Quoted: value"
      assert frontmatter["flag"] == true
    end

    test "ignores comment lines" do
      assert {:ok, frontmatter} =
               YamlFrontmatter.parse("---\n# a comment\ndescription: Value\n---\n")

      assert frontmatter == %{"description" => "Value"}
    end

    test "treats an unterminated flow collection as missing" do
      assert {:ok, frontmatter} = YamlFrontmatter.parse("---\ndescription: [unclosed\n---\n")

      assert frontmatter["description"] == nil
    end
  end

  describe "list/1" do
    test "reads flow lists with plain and quoted items" do
      assert YamlFrontmatter.list(~s(["read", "bash"])) == {:ok, ["read", "bash"]}
      assert YamlFrontmatter.list("['read', 'it''s']") == {:ok, ["read", "it's"]}
      assert YamlFrontmatter.list("[read, bash]") == {:ok, ["read", "bash"]}
      assert YamlFrontmatter.list(~s(["a, b", "c\\"d"])) == {:ok, ["a, b", ~s(c"d)]}
      assert YamlFrontmatter.list("[{lib,test}/**, '*.md']") == {:ok, ["{lib,test}/**", "*.md"]}
      assert YamlFrontmatter.list("[]") == {:ok, []}
      assert YamlFrontmatter.list(~s(["a" \t , "b"\t \t])) == {:ok, ["a", "b"]}
    end

    test "reads block lists as parse/1 returns them" do
      {:ok, frontmatter} =
        YamlFrontmatter.parse("---\ntools:\n  - read\n  - \"bash\"\n  - 'edit'\n---\n")

      assert YamlFrontmatter.list(frontmatter["tools"]) == {:ok, ["read", "bash", "edit"]}
      assert YamlFrontmatter.list("- lib/**\n-\n- test/**") == {:ok, ["lib/**", "test/**"]}
    end

    test "reads comma- and newline-separated items" do
      assert YamlFrontmatter.list("read, bash") == {:ok, ["read", "bash"]}
      assert YamlFrontmatter.list("read\nbash,, edit") == {:ok, ["read", "bash", "edit"]}
      assert YamlFrontmatter.list(~s("read", 'bash')) == {:ok, ["read", "bash"]}
      assert YamlFrontmatter.list("lib/**/*.ex") == {:ok, ["lib/**/*.ex"]}
      assert YamlFrontmatter.list("  ") == {:ok, []}
    end

    test "rejects malformed lists and values that are not strings" do
      for value <- [~s(["read]), "['read]", ~s(["read" bash]), "- read\nbash", true, nil, 1] do
        assert YamlFrontmatter.list(value) == {:error, :malformed_list}, inspect(value)
      end
    end
  end
end
