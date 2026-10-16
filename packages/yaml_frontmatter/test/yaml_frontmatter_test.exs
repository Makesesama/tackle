defmodule YamlFrontmatterTest do
  use ExUnit.Case, async: true

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
end
