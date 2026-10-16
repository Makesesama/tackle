defmodule Tackle.Review.FindingTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Diff, Finding}

  @input %{
    "title" => "  Return an error when the user is missing  ",
    "category" => "correctness",
    "severity" => "high",
    "blocking" => true,
    "confidence" => 0.8,
    "rule_id" => "missing-nil-check",
    "location" => %{
      "path" => "lib/users.ex",
      "side" => "new",
      "start_line" => 12,
      "end_line" => 13
    },
    "trigger" => "find/1 returns nil for an unknown id",
    "body" => "`user.email` raises when the lookup finds nothing.",
    "suggestion" => "with %User{} = user <- find(id), do: user.email"
  }

  defp errors(input, opts \\ []) do
    assert {:error, errors} = Finding.from_input(input, opts)
    errors
  end

  describe "from_input/2" do
    test "builds a finding with derived fields unset" do
      assert {:ok, finding} = Finding.from_input(@input)

      assert finding == %Finding{
               title: "Return an error when the user is missing",
               category: :correctness,
               severity: :high,
               blocking: true,
               confidence: 0.8,
               rule_id: "missing-nil-check",
               location: %{path: "lib/users.ex", side: :new, start_line: 12, end_line: 13},
               trigger: "find/1 returns nil for an unknown id",
               body: "`user.email` raises when the lookup finds nothing.",
               suggestion: "with %User{} = user <- find(id), do: user.email",
               support: 1,
               verdict: nil,
               fingerprint: nil
             }
    end

    test "nullable fields may be omitted, null, or blank; unknown keys are ignored" do
      for value <- [:omit, nil, "  "] do
        input =
          if value == :omit,
            do: Map.drop(@input, ["rule_id", "suggestion"]),
            else: Map.merge(@input, %{"rule_id" => value, "suggestion" => value})

        assert {:ok, %Finding{rule_id: nil, suggestion: nil}} =
                 Finding.from_input(Map.put(input, "support", 5))
      end
    end

    test "accepts integer confidences as floats" do
      assert {:ok, %Finding{confidence: 1.0}} = Finding.from_input(%{@input | "confidence" => 1})
      assert {:ok, %Finding{confidence: +0.0}} = Finding.from_input(%{@input | "confidence" => 0})
    end

    test "reports every missing field" do
      assert errors(%{}) == [
               "title: is required",
               "category: is required",
               "severity: is required",
               "blocking: is required",
               "confidence: is required",
               "location: is required",
               "trigger: is required",
               "body: is required"
             ]
    end

    test "reports invalid values" do
      input = %{
        "title" => String.duplicate("x", 81),
        "category" => "style",
        "severity" => :high,
        "blocking" => "yes",
        "confidence" => 1.5,
        "rule_id" => 7,
        "location" => %{"path" => " ", "side" => "both", "start_line" => 0, "end_line" => "2"},
        "trigger" => "",
        "body" => 3,
        "suggestion" => ["x"]
      }

      assert errors(input) == [
               "title: must be at most 80 characters",
               "category: must be one of correctness, security, performance, maintainability, readability, testing",
               "severity: must be one of blocker, high, medium, low",
               "blocking: must be true or false",
               "confidence: must be a number from 0 to 1",
               "rule_id: must be a string or null",
               "location.path: must not be empty",
               "location.side: must be new or old",
               "location.start_line: must be a positive integer",
               "location.end_line: must be a positive integer",
               "trigger: must not be empty",
               "body: must be a string",
               "suggestion: must be a string or null"
             ]
    end

    test "checks the location shape and range" do
      assert errors(%{@input | "location" => "lib/users.ex:12"}) == [
               "location: must be an object"
             ]

      assert errors(%{@input | "location" => %{}}) == [
               "location.path: is required",
               "location.side: is required",
               "location.start_line: is required",
               "location.end_line: is required"
             ]

      reversed = %{@input["location"] | "start_line" => 14}

      assert errors(%{@input | "location" => reversed}) == [
               "location.end_line: must not be less than location.start_line"
             ]

      old = %{@input["location"] | "side" => "old", "end_line" => 12}

      assert {:ok, %Finding{location: %{side: :old, start_line: 12, end_line: 12}}} =
               Finding.from_input(%{@input | "location" => old})
    end

    test "limits the trigger, body, and suggestion lengths" do
      input = %{
        @input
        | "trigger" => String.duplicate("t", 501),
          "body" => String.duplicate("b", 1_001),
          "suggestion" => String.duplicate("s", 2_001)
      }

      assert errors(input) == [
               "trigger: must be at most 500 characters",
               "body: must be at most 1000 characters",
               "suggestion: must be at most 2000 characters"
             ]
    end

    test "checks rule ids against the applicable rules when given" do
      assert {:ok, _finding} = Finding.from_input(@input, rule_ids: ["missing-nil-check"])

      assert errors(@input, rule_ids: ["injection", "resource-leak"]) == [
               ~s(rule_id: unknown rule "missing-nil-check"; use one of injection, resource-leak or null)
             ]

      assert errors(@input, rule_ids: []) == [
               ~s(rule_id: unknown rule "missing-nil-check"; no rules apply, use null)
             ]

      assert {:ok, %Finding{rule_id: nil}} =
               Finding.from_input(%{@input | "rule_id" => nil}, rule_ids: [])
    end

    test "rejects non-object input" do
      assert errors([@input]) == ["finding: must be an object"]
      assert errors(nil) == ["finding: must be an object"]
    end
  end

  describe "json_schema/0" do
    test "requires every property and matches the enums" do
      schema = Finding.json_schema()
      assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(schema["properties"]))
      location = schema["properties"]["location"]
      assert Enum.sort(location["required"]) == Enum.sort(Map.keys(location["properties"]))

      assert schema["properties"]["category"]["enum"] ==
               Enum.map(Finding.categories(), &Atom.to_string/1)

      assert schema["properties"]["severity"]["enum"] ==
               Enum.map(Finding.severities(), &Atom.to_string/1)

      assert schema |> JSON.encode!() |> JSON.decode!() == schema
    end

    test "describes input that from_input/2 accepts" do
      assert @input |> JSON.encode!() |> JSON.decode!() |> Finding.from_input() |> elem(0) == :ok
    end
  end

  describe "excerpt/2" do
    setup do
      {:ok, %Diff{files: [%{hunks: [%{lines: lines}]}]}} =
        Diff.parse("""
        diff --git a/lib/users.ex b/lib/users.ex
        --- a/lib/users.ex
        +++ b/lib/users.ex
        @@ -10,3 +10,4 @@ defmodule Users do
           def email(id) do
        -    find(id).email
        +    user = find(id)
        +    user.email
           end
        """)

      %{lines: lines}
    end

    test "selects new-side lines by new number", %{lines: lines} do
      location = %{path: "lib/users.ex", side: :new, start_line: 11, end_line: 13}
      assert Finding.excerpt(lines, location) == "    user = find(id)\n    user.email\n  end"
    end

    test "selects old-side lines by old number", %{lines: lines} do
      location = %{path: "lib/users.ex", side: :old, start_line: 10, end_line: 11}
      assert Finding.excerpt(lines, location) == "  def email(id) do\n    find(id).email"
    end

    test "is empty outside the lines", %{lines: lines} do
      assert Finding.excerpt(lines, %{side: :new, start_line: 40, end_line: 41}) == ""
    end
  end

  describe "fingerprint/2" do
    setup do
      {:ok, finding} = Finding.from_input(@input)
      %{finding: finding, code: "  user = find(id)\n  user.email\n"}
    end

    test "is 32 lowercase hex characters and set by put_fingerprint/2", %{finding: f, code: code} do
      fingerprint = Finding.fingerprint(f, code)
      assert fingerprint =~ ~r/\A[0-9a-f]{32}\z/
      assert Finding.put_fingerprint(f, code).fingerprint == fingerprint
    end

    test "ignores line numbers, whitespace, punctuation, and other fields", %{
      finding: f,
      code: code
    } do
      fingerprint = Finding.fingerprint(f, code)

      same = %{
        f
        | title: "return an error, when the user is missing!",
          location: %{f.location | start_line: 40, end_line: 41},
          severity: :low,
          confidence: 0.1,
          body: "Different wording.",
          support: 3
      }

      assert Finding.fingerprint(same, "\n\tuser  =  find(id)\n\n    user.email") == fingerprint
    end

    test "changes with the path, rule, title, and code", %{finding: f, code: code} do
      fingerprint = Finding.fingerprint(f, code)

      for changed <- [
            %{f | location: %{f.location | path: "lib/accounts.ex"}},
            %{f | rule_id: "unhandled-error"},
            %{f | title: "Check the user"}
          ] do
        refute Finding.fingerprint(changed, code) == fingerprint
      end

      refute Finding.fingerprint(f, "user = find!(id)\nuser.email") == fingerprint
    end

    test "uses the category for findings without a rule", %{finding: f, code: code} do
      defect = %{f | rule_id: nil}
      refute Finding.fingerprint(defect, code) == Finding.fingerprint(f, code)

      refute Finding.fingerprint(%{defect | category: :security}, code) ==
               Finding.fingerprint(defect, code)

      assert Finding.fingerprint(%{f | category: :security}, code) ==
               Finding.fingerprint(f, code)
    end

    test "accepts invalid UTF-8 in the code", %{finding: f} do
      assert Finding.fingerprint(f, <<"a ", 0xFF, " b">>) =~ ~r/\A[0-9a-f]{32}\z/
    end
  end
end
