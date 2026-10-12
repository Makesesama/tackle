defmodule Tackle.Review.FunctionContextTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Change, Diff, FunctionContext}
  alias Tackle.Test.GitRepo

  doctest FunctionContext

  # Lines of `snippet` that start a function in `path`. In the snippets, the
  # expected function lines are marked with `>` in the first column, which
  # is replaced by a space before matching.
  defp assert_function_lines(path, snippet) do
    lines = String.split(snippet, "\n", trim: true)
    patterns = FunctionContext.patterns(path)

    expected = for ">" <> line <- lines, do: line

    source =
      Enum.map(lines, fn
        ">" <> line -> line
        line -> line
      end)

    assert Enum.filter(source, &FunctionContext.function_line?(patterns, &1)) == expected
  end

  describe "language/1" do
    test "chooses languages by extension and file name" do
      assert FunctionContext.language("lib/a.ex") == :elixir
      assert FunctionContext.language("test/a_test.exs") == :elixir
      assert FunctionContext.language("src/main.rs") == :rust
      assert FunctionContext.language("app/Main.KT") == :kotlin
      assert FunctionContext.language("web/app.tsx") == :javascript
      assert FunctionContext.language("include/a.hpp") == :cpp
      assert FunctionContext.language("Rakefile") == :ruby
      assert FunctionContext.language("README") == nil
      assert FunctionContext.language("data.json") == nil
    end

    test "lists the languages with patterns" do
      assert FunctionContext.languages() ==
               ~w(bash cpp csharp css elixir golang html java javascript kotlin markdown php python ruby rust)a
    end
  end

  describe "function_line?/2" do
    test "elixir: definitions at any indentation, not calls or the body" do
      assert_function_lines("lib/shop.ex", """
      >defmodule Shop do
        @moduledoc "A shop."
        use GenServer
      >  def total(items) do
          Enum.sum(items)
        end
      >  defp discount(total, percent), do: total * percent
      >  defmacro shout(name), do: name
      >  defmacrop whisper(name), do: name
      >  defguard is_price(x) when is_number(x)
      >  defdelegate fetch(id), to: Repo
      >  defimpl String.Chars, for: Shop do
      >  defprotocol Priced do
        defstruct [:items]
        default = 1
        define(:x)
      end
      """)
    end

    test "elixir: tests in test files" do
      assert_function_lines("test/shop_test.exs", """
      >defmodule ShopTest do
        use ExUnit.Case
        describe "total/1" do
      >    test "sums prices" do
            assert Shop.total([1, 2]) == 3
            testing = true
          end
        end
      end
      """)
    end

    test "rust" do
      assert_function_lines("src/lib.rs", """
      >pub struct Cart {
          items: Vec<Item>,
      }
      >impl Cart {
      >    pub fn total(&self) -> u64 {
              self.items.iter().map(|i| i.price).sum()
          }
      >    pub(crate) async fn load(id: u64) -> Self {
      >    unsafe fn raw(&self) {}
      >    extern "C" fn callback() {}
          fn declared();
          let x = fn_call();
      }
      >pub trait Priced {
      >mod tests {
      >macro_rules! cart {
      """)
    end

    test "python" do
      assert_function_lines("shop.py", """
      >class Cart:
          @property
      >    def total(self):
              return sum(self.items)
      >    async def load(self, id):
              definitely = True
      """)
    end

    test "golang" do
      assert_function_lines("cart.go", """
      package cart
      >type Cart struct {
          Items []Item
      }
      >type Priced interface {
      >func (c *Cart) Total() int {
          return sum(c.Items)
      }
      >func New() *Cart {
      """)
    end

    test "java: methods and types, not statements" do
      assert_function_lines("Cart.java", """
      package shop;
      >public class Cart {
          private final List<Item> items = new ArrayList<>();
      >    public int total() {
              for (Item item : items) {
              if (items.isEmpty()) {
              return items.size();
              new Cart();
          }
      >    double average(int[] xs) {
      >    static <T> List<T> format(Map<String, T> values) {
      >    public enum Kind {
      >    record Point(int x, int y) {}
      }
      """)
    end

    test "kotlin" do
      assert_function_lines("Cart.kt", """
      >class Cart(val items: List<Item>) {
      >    fun total(): Int = items.sumOf { it.price }
      >    private suspend fun load() {
              val funds = 1
          }
      }
      >interface Priced
      """)
    end

    test "csharp: methods, properties, and types, not statements" do
      assert_function_lines("Cart.cs", """
      >namespace Shop
      {
      >    public sealed class Cart
          {
              public List<Item> Items { get; set; }
      >        public int Count
      >        public int Total(int discount)
              {
                  if (discount > 0)
                  return Items.Count;
                  var x = Compute(1);
                  foreach (var item in Items)
              }
      >        public async Task<Dictionary<string, int>> LoadAsync(string id)
          }
      >    internal record Point(int X, int Y);
      }
      """)
    end

    test "cpp: top-level lines, not labels" do
      assert_function_lines("cart.cpp", """
      >int total(const Cart& cart)
      {
          int sum = 0;
      again:
          return sum;
      }
      >class Cart {
      public:
        int size() const;
      };
      >static void helper(void) {}
      >::std::string name()
      """)
    end

    test "ruby" do
      assert_function_lines("cart.rb", """
      >module Shop
      >  class Cart
      >    def total
            items.sum(&:price)
          end
      >    def self.load(id)
            defined?(x)
          end
        end
      end
      """)
    end

    test "php" do
      assert_function_lines("Cart.php", """
      <?php
      >final class Cart
      {
      >    public function total(): int
          {
              return array_sum($this->items);
          }
      >    private static function load($id) {}
      >    function helper() {}
      }
      >interface Priced {}
      >trait Discounts {}
      """)
    end

    test "bash" do
      assert_function_lines("deploy.sh", """
      #!/bin/sh
      set -eu
      >build() {
        make all
      }
      >function deploy {
        build
      }
      >function release() {
      >  nested_name ( ) {
      echo "done"
      """)
    end

    test "css: selectors and at-rules, not declarations" do
      assert_function_lines("app.css", """
      >.cart {
        color: red;
        margin: 0;
      }
      >#main, .Footer {
      >@media (max-width: 600px) {
        h1 {
      >:root {
      >A:hover {
      """)
    end

    test "html: headings" do
      assert_function_lines("index.html", """
      <body>
      >  <h1>Shop</h1>
        <p>Welcome</p>
      >  <H2 class="sub">Cart</H2>
        <header>Top</header>
      """)
    end

    test "markdown: headings" do
      assert_function_lines("README.md", """
      >#  Shop
      Some text.
      >## Usage
      >   ### Indented
          #### code, not a heading
      #hashtag
      """)
    end

    test "javascript and typescript" do
      assert_function_lines("cart.ts", """
      import { sum } from "./sum";
      >export default function total(items: Item[]): number {
      >function* ids() {
      >export async function load(id) {
      >export class Cart extends Base {
      >  constructor(items) {
      >  async refresh(): Promise<void> {
      >  static of<T>(items: T[]) {
      >  get size() {
      >  private handle = async (event: Event) => {
          if (this.items.length > 0) {
          for (const item of this.items) {
          while (x) {
          return sum(this.items);
          this.render();
        }
      }
      >export const totalOf = (items) => items.length;
      >const handler = async function (req, res) {
      >let parse = value => {
      >export interface Priced {
      >export type Id = string;
      >enum Kind {
      >  it("totals the cart", async () => {
      const count = items.length;
      const config = { a: 1 };
      describe.each(cases)("x", () => {
      } else if (x) {
      """)
    end

    test "other files use Git's default rule" do
      assert_function_lines("notes.txt", """
      >Introduction
        indented
      >_private
      >$var
      1. numbered
      # comment
      """)
    end

    test "ignores a carriage return at the end of a line" do
      patterns = FunctionContext.patterns("a.ex")
      assert FunctionContext.function_line?(patterns, "  def total(x)\r")
    end

    test "never matches very long lines" do
      patterns = FunctionContext.patterns("a.ex")
      refute FunctionContext.function_line?(patterns, "  def f" <> String.duplicate("x", 1_000))

      refute FunctionContext.function_line?(
               FunctionContext.patterns("a.txt"),
               String.duplicate("x", 1_001)
             )
    end

    test "does not need valid UTF-8" do
      patterns = FunctionContext.patterns("a.ex")
      assert FunctionContext.function_line?(patterns, <<"  def caf", 0xE9, "(x)">>)
      refute FunctionContext.function_line?(patterns, <<0xFF, 0xFE>>)
    end
  end

  describe "regions/1" do
    # A diff file of `path` from `old` to `new`, built by Git.
    defp file(path, old, new) do
      dir = GitRepo.init("function-context")
      GitRepo.write(dir, %{path => old})
      GitRepo.commit(dir, "base")
      GitRepo.write(dir, %{path => new})
      assert {:ok, %{diff: %Diff{files: [file]}}} = Change.load(cwd: dir)
      file
    end

    defp new_numbers(regions) do
      Enum.map(regions, fn lines ->
        numbers = for %{new: new} <- lines, new != nil, do: new
        Enum.min(numbers)..Enum.max(numbers)
      end)
    end

    defp texts(lines), do: Enum.map(lines, & &1.text)

    @module """
    defmodule Shop do
      @moduledoc "A shop."

      alias Shop.Item

      def total(items) do
        items
        |> Enum.map(& &1.price)
        |> Enum.sum()
      end

      @doc "Applies a discount."
      @spec discount(number(), number()) :: number()
      def discount(total, percent) do
        rate = percent / 100
        total - total * rate
      end

      defp round(x) do
        Float.round(x, 2)
      end

      def tax(total), do: total * 0.2
    end
    """

    test "an Elixir change expands to its function, not the module" do
      new = String.replace(@module, "|> Enum.sum()", "|> Enum.sum(0)")

      assert [lines] = "lib/shop.ex" |> file(@module, new) |> FunctionContext.regions()
      assert List.first(texts(lines)) == "  def total(items) do"
      assert new_numbers([lines]) == [6..12]
      assert "  def total(items) do" in texts(lines)
      refute "defmodule Shop do" in texts(lines)
      refute "  def discount(total, percent) do" in texts(lines)
    end

    test "includes the attributes and documentation directly above the function" do
      new = String.replace(@module, "rate = percent / 100", "rate = percent / 100.0")

      assert [lines] = "lib/shop.ex" |> file(@module, new) |> FunctionContext.regions()
      assert new_numbers([lines]) == [12..18]

      assert Enum.take(texts(lines), 3) == [
               "  @doc \"Applies a discount.\"",
               "  @spec discount(number(), number()) :: number()",
               "  def discount(total, percent) do"
             ]
    end

    test "a change in a function's documentation belongs to that function" do
      new = String.replace(@module, "Applies a discount.", "Applies a percentage discount.")

      assert [lines] = "lib/shop.ex" |> file(@module, new) |> FunctionContext.regions()
      # The plain hunk's context reaches up to line 9; the function runs to 17.
      assert new_numbers([lines]) == [9..17]
      assert List.last(texts(lines)) == "  end"
    end

    test "ends before the next function line, without blank lines" do
      body = Enum.map_join(1..10, "\n", &"    x#{&1} = #{&1}")
      old = "defmodule A do\n  def a do\n#{body}\n  end\n\n\n\n\n  def b, do: 1\nend\n"
      new = String.replace(old, "x1 = 1", "x1 = 0")

      assert [lines] = "a.ex" |> file(old, new) |> FunctionContext.regions()
      assert new_numbers([lines]) == [1..13]
      assert List.last(texts(lines)) == "  end"
    end

    test "an added function expands to itself, not the function above" do
      new =
        String.replace(@module, "  def tax(total)", """
          @doc "Shipping costs."
          def shipping(items) do
            length(items) * 5
          end

          def tax(total)\
        """)

      assert [lines] = "lib/shop.ex" |> file(@module, new) |> FunctionContext.regions()
      # Only the hunk's own context comes from `round/1`.
      refute "  defp round(x) do" in texts(lines)
      assert "  def shipping(items) do" in texts(lines)
    end

    test "the end of a function body is not the next function's header" do
      old = """
      defmodule A do
        def a(x) do
          y = x + 1
          y = y + 1
          y = y + 1
          y = y + 1

          y * 2
        end
        def b(x) do
          x
          x
          x
          x
        end
      end
      """

      new = String.replace(old, "y * 2", "y * 3")

      assert [lines] = "a.ex" |> file(old, new) |> FunctionContext.regions()
      assert new_numbers([lines]) == [2..11]
      assert List.first(lines).text == "  def a(x) do"
    end

    test "a decorator belongs to the function below it" do
      old = """
      class Cart:
          def total(self):
              items = self.items
              prices = [item.price for item in items]
              return sum(prices)

          @property
          def size(self):
              return len(self.items)
      """

      new = String.replace(old, "@property", "@cached_property")

      assert [lines] = "cart.py" |> file(old, new) |> FunctionContext.regions()
      assert List.last(lines).text == "        return len(self.items)"
      refute "    def total(self):" in texts(lines)
    end

    test "changes in one function share a region; others get their own" do
      new =
        @module
        |> String.replace("  @moduledoc \"A shop.\"", "  @moduledoc \"The shop.\"")
        |> String.replace(
          "items\n    |> Enum.map",
          "items\n    |> Enum.reject(&is_nil/1)\n    |> Enum.map"
        )
        |> String.replace("Float.round(x, 2)", "Float.round(x, 3)")
        |> String.replace("total * 0.2", "total * 0.25")

      file = file("lib/shop.ex", @module, new)
      regions = FunctionContext.regions(file)

      # The moduledoc and `total/1` share a region, which ends before
      # `discount/2` and its header; so do `round/1` and `tax/1`.
      assert new_numbers(regions) == [1..11, 18..25]
    end

    test "without a function line above, the region starts at the top" do
      old = "  one\n  two\n  three\n  four\n  five\n  six\n  seven\n"
      new = String.replace(old, "six", "SIX")

      assert [lines] = "notes.txt" |> file(old, new) |> FunctionContext.regions()
      assert new_numbers([lines]) == [1..7]
    end

    test "marks the last line of a file without a final newline" do
      old = "def a\n  one\n  two\n  three\n  four\n  five\n  six\n  end"
      new = String.replace(old, "one", "ONE")

      assert [lines] = "a.rb" |> file(old, new) |> FunctionContext.regions()
      assert %{text: "  end", new: 8, no_newline: true} = List.last(lines)
      assert Enum.count(lines, & &1.no_newline) == 1
    end

    test "numbers context lines on both sides after earlier changes" do
      old =
        "def a\n  1\nend\n" <> Enum.map_join(1..10, "", &"  pad#{&1}\n") <> "def b\n  2\nend\n"

      new =
        old
        |> String.replace("  1\n", "  1\n  1b\n")
        |> String.replace("  2\n", "  two\n")

      # `pad7` lies between the two hunks and comes from the contents.
      assert [lines] = "a.rb" |> file(old, new) |> FunctionContext.regions()
      assert %{kind: :context, old: 10, new: 11} = Enum.find(lines, &(&1.text == "  pad7"))
      assert %{kind: :context, old: 14, new: 15} = Enum.find(lines, &(&1.text == "def b"))
    end

    test "keeps the plain hunks when the contents are missing" do
      {:ok, %Diff{files: [file]}} =
        Diff.parse("""
        --- a/a.ex
        +++ b/a.ex
        @@ -10,3 +10,3 @@
           def f do
        -    1
        +    2
           end
        """)

      assert FunctionContext.regions(file) == Enum.map(file.hunks, & &1.lines)
      assert FunctionContext.regions(%{file | hunks: []}) == []
    end

    test "keeps the plain hunks when the contents do not fit the hunks" do
      {:ok, %Diff{files: [file]}} =
        Diff.parse("""
        --- a/a.ex
        +++ b/a.ex
        @@ -10,3 +10,3 @@
           def f do
        -    1
        +    2
           end
        """)

      file = %{file | new_content: "too\nshort\n"}
      assert FunctionContext.regions(file) == Enum.map(file.hunks, & &1.lines)
    end
  end
end
