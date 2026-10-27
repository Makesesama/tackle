defmodule Tackle.Lib.DecisionTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.{Answer, Question, Request, Result, Selection}
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.Usage

  defmodule FakeDecisionAdapter do
    @behaviour Tackle.Lib.LLM
    @behaviour Tackle.Lib.Decision

    @impl Tackle.Lib.LLM
    def adapter_id, do: "fake-local"

    @impl Tackle.Lib.LLM
    def models, do: ["chat-model"]

    @impl Tackle.Lib.LLM
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl Tackle.Lib.Decision
    def decision_models, do: ["judge:4b", "org/judge"]

    @impl Tackle.Lib.Decision
    def decide(%Request{} = request, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:decide, request, opts})

      case Keyword.get(opts, :reply) do
        :raise ->
          raise "judge exploded"

        :throw ->
          throw(:judge_threw)

        :exit ->
          exit(:judge_exited)

        nil ->
          answers =
            Map.new(request.questions, fn %Question{name: name} ->
              {name,
               %Answer{
                 type: :choice,
                 choice: "stalled",
                 probabilities: %{"progressing" => 0.07, "stalled" => 0.93},
                 confidence: 0.9
               }}
            end)

          {:ok, %Result{answers: answers, usage: %{"input_tokens" => 120, "output_tokens" => 3}}}

        reply ->
          reply
      end
    end
  end

  defmodule ChatOnlyAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "chat-only"

    @impl true
    def models, do: ["gpt"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule DuplicateDecisionAdapter do
    def adapter_id, do: "fake-local"
    def decision_models, do: ["judge:4b"]
    def decide(_request, _opts), do: {:error, :not_used}
  end

  defmodule BadModelsAdapter do
    def adapter_id, do: "bad-models"
    def decision_models, do: ["dup", "dup"]
    def decide(_request, _opts), do: {:error, :not_used}
  end

  defmodule RaisingModelsAdapter do
    def adapter_id, do: "raising"
    def decision_models, do: raise("boom")
    def decide(_request, _opts), do: {:error, :not_used}
  end

  defmodule LocalDecisionAdapter do
    @behaviour Tackle.Lib.Decision

    def adapter_id, do: "local"

    @impl true
    def decision_models, do: ["judge"]

    @impl true
    def decide(_request, _opts), do: {:error, :not_used}

    @impl true
    def local?, do: true
  end

  defmodule DecideOnlyAdapter do
    def adapter_id, do: "decide-only"
    def decide(_request, _opts), do: {:error, :not_used}
  end

  defmodule BadLocalFlagAdapter do
    def adapter_id, do: "bad-local"
    def decision_models, do: ["judge"]
    def decide(_request, _opts), do: {:error, :not_used}
    def local?, do: :yes
  end

  defp verdict_question do
    Question.choice("verdict", "Is the command stuck?", %{
      "progressing" => "Output still advances",
      "stalled" => nil
    })
  end

  defp request(questions, state \\ "state"), do: Request.new(state, questions, "judge:4b")

  defp selection do
    {:ok, selection} =
      Decision.select([ChatOnlyAdapter, FakeDecisionAdapter], "fake-local/judge:4b")

    selection
  end

  describe "select/2" do
    test "resolves a decision model among mixed adapters" do
      assert {:ok,
              %Selection{
                adapter: FakeDecisionAdapter,
                provider_id: "fake-local",
                model: "judge:4b",
                ref: "fake-local/judge:4b"
              }} = Decision.select([ChatOnlyAdapter, FakeDecisionAdapter], "fake-local/judge:4b")
    end

    test "only the first slash separates the adapter id" do
      assert {:ok, %Selection{model: "org/judge"}} =
               Decision.select([FakeDecisionAdapter], "fake-local/org/judge")
    end

    test "returns explicit errors for bad references, adapters, and models" do
      adapters = [ChatOnlyAdapter, FakeDecisionAdapter]

      assert Decision.select(adapters, "no-slash") == {:error, {:invalid_model_ref, "no-slash"}}
      assert Decision.select(adapters, "Bad/x") == {:error, {:invalid_model_ref, "Bad/x"}}
      assert Decision.select(adapters, 42) == {:error, {:invalid_model_ref, 42}}
      assert Decision.select(adapters, "missing/x") == {:error, {:unknown_provider, "missing"}}

      assert Decision.select(adapters, "chat-only/gpt") ==
               {:error, {:unsupported_decision_adapter, "chat-only"}}

      # Chat models are not decision models.
      assert Decision.select(adapters, "fake-local/chat-model") ==
               {:error, {:unknown_decision_model, "fake-local/chat-model"}}

      assert Decision.select(
               [FakeDecisionAdapter, DuplicateDecisionAdapter],
               "fake-local/judge:4b"
             ) ==
               {:error, {:duplicate_provider_id, "fake-local"}}

      assert Decision.select([BadModelsAdapter], "bad-models/dup") ==
               {:error, {:duplicate_model_id, "bad-models", "dup"}}

      assert {:error, {:adapter_callback_failed, RaisingModelsAdapter, :decision_models, "boom"}} =
               Decision.select([RaisingModelsAdapter], "raising/x")

      assert {:error, {:invalid_adapter, Nope.Missing, {:not_loaded, _}}} =
               Decision.select([Nope.Missing], "fake-local/judge:4b")
    end

    test "decision_adapter?/1 names adapters that implement the contract" do
      assert Decision.decision_adapter?(FakeDecisionAdapter)
      assert Decision.decision_adapter?(LocalDecisionAdapter)
      refute Decision.decision_adapter?(ChatOnlyAdapter)
      refute Decision.decision_adapter?(DecideOnlyAdapter)
      refute Decision.decision_adapter?(Nope.Missing)
      refute Decision.decision_adapter?("fake-local")
    end

    test "marks selections local only when the adapter declares it" do
      assert {:ok, %Selection{local: true}} =
               Decision.select([LocalDecisionAdapter], "local/judge")

      # Adapters without `local?/0` are remote.
      assert {:ok, %Selection{local: false}} =
               Decision.select([FakeDecisionAdapter], "fake-local/judge:4b")

      assert Decision.select([BadLocalFlagAdapter], "bad-local/judge") ==
               {:error, {:invalid_local_flag, "bad-local", :yes}}
    end
  end

  describe "decide/3 and ask/4" do
    test "sends a validated request with the selection model and normalizes usage" do
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)

      assert {:ok, %Result{} = result} =
               Decision.ask(selection(), %{"command" => "make test"}, [verdict_question()],
                 test_pid: self(),
                 cancellation_signal: signal,
                 receive_timeout: 5_000
               )

      assert_receive {:decide, %Request{} = request, opts}
      assert request.model == "judge:4b"
      assert request.state == %{"command" => "make test"}
      assert Keyword.fetch!(opts, :receive_timeout) == 5_000
      assert Keyword.fetch!(opts, :cancellation_signal) == signal

      assert result.model == "judge:4b"

      assert %Usage{input_tokens: 120, output_tokens: 3, total_tokens: 123} = result.usage
      assert result.usage.provider == "fake-local"

      assert %Answer{choice: "stalled"} = answer = result.answers["verdict"]
      assert Answer.choice_probability(answer) == 0.93
    end

    test "accepts a prebuilt request and overrides its model" do
      request = Request.new("output tail", [verdict_question()], "other")

      assert {:ok, %Result{}} = Decision.decide(selection(), request, test_pid: self())
      assert_receive {:decide, %Request{model: "judge:4b"}, _opts}

      assert {:ok, %Result{}} = Decision.decide(selection(), request)
    end

    test "does not call the adapter for a cancelled signal" do
      signal = Cancellation.new_signal()
      Cancellation.cancel(signal, :stop)
      on_exit(fn -> Cancellation.delete(signal) end)

      assert Decision.ask(selection(), "state", [verdict_question()],
               test_pid: self(),
               cancellation_signal: signal
             ) == {:error, :cancelled}

      refute_receive {:decide, _request, _opts}
    end

    test "passes adapter errors through" do
      assert Decision.ask(selection(), "state", [verdict_question()],
               reply: {:error, {:http_error, 500, "boom"}}
             ) == {:error, {:http_error, 500, "boom"}}
    end

    test "turns an adapter that raises, throws, or exits into an unknown LLM error" do
      assert {:error, %Error{kind: :unknown} = error} =
               Decision.ask(selection(), "state", [verdict_question()], reply: :raise)

      assert error.message =~ "The decision adapter #{inspect(FakeDecisionAdapter)} failed"
      assert error.message =~ "judge exploded"

      assert %{adapter: FakeDecisionAdapter, kind: :error, reason: %RuntimeError{}} =
               error.details

      assert is_list(error.details.stacktrace)

      assert {:error, %Error{kind: :unknown, details: %{kind: :throw, reason: :judge_threw}}} =
               Decision.ask(selection(), "state", [verdict_question()], reply: :throw)

      assert {:error, %Error{kind: :unknown, details: %{kind: :exit, reason: :judge_exited}}} =
               Decision.ask(selection(), "state", [verdict_question()], reply: :exit)
    end

    test "rejects returns that are not results" do
      for reply <- [{:ok, %{}}, :ok, "stalled", {:ok, %Result{answers: %{}}, :extra}] do
        assert {:error,
                %Error{kind: :invalid_response, details: %{reason: {:result, ^reply}, usage: nil}}} =
                 Decision.ask(selection(), "state", [verdict_question()], reply: reply)
      end
    end

    test "rejects answers that do not answer the questions" do
      questions = [
        verdict_question(),
        Question.noul("waiting", "Waiting for input?"),
        Question.score("urgency", "How urgent?", ["low", "mid", "high"])
      ]

      good = %{
        "verdict" => %Answer{type: :choice, choice: "stalled"},
        "waiting" => %Answer{type: :noul, noul: 0.5, probabilities: %{"true" => 0.5}},
        "urgency" => %Answer{type: :score, score: 1.4, probabilities: %{0 => 0.1, 2 => 0.5}}
      }

      assert {:ok, %Result{answers: ^good}} =
               Decision.ask(selection(), "state", questions, reply: {:ok, %Result{answers: good}})

      invalid = [
        {nil, {:answers, nil}},
        {[], {:answers, []}},
        {Map.delete(good, "waiting"), {:missing_answer, "waiting"}},
        {Map.put(good, "extra", %Answer{type: :noul, noul: 0.5}), {:unexpected_answer, "extra"}},
        {%{good | "verdict" => %{type: :choice, choice: "stalled"}},
         {:invalid_answer, "verdict", :not_an_answer}},
        {%{good | "verdict" => %Answer{type: :noul, noul: 0.5}},
         {:invalid_answer, "verdict", :type}},
        {%{good | "verdict" => %Answer{type: :choice, choice: "maybe"}},
         {:invalid_answer, "verdict", :choice}},
        {%{good | "verdict" => %Answer{type: :choice, choice: nil}},
         {:invalid_answer, "verdict", :choice}},
        {%{good | "waiting" => %Answer{type: :noul, noul: 1.5}},
         {:invalid_answer, "waiting", :noul}},
        {%{good | "waiting" => %Answer{type: :noul, noul: "0.5"}},
         {:invalid_answer, "waiting", :noul}},
        {%{good | "urgency" => %Answer{type: :score, score: 3}},
         {:invalid_answer, "urgency", :score}},
        {%{good | "urgency" => %Answer{type: :score, score: -1}},
         {:invalid_answer, "urgency", :score}},
        {%{good | "verdict" => %Answer{type: :choice, choice: "stalled", probabilities: nil}},
         {:invalid_answer, "verdict", :probabilities}},
        {%{
           good
           | "verdict" => %Answer{
               type: :choice,
               choice: "stalled",
               probabilities: %{"stalled" => "0.9"}
             }
         }, {:invalid_answer, "verdict", :probabilities}},
        {%{
           good
           | "verdict" => %Answer{
               type: :choice,
               choice: "stalled",
               probabilities: %{"unknown" => 0.9}
             }
         }, {:invalid_answer, "verdict", :probabilities}},
        {%{good | "urgency" => %Answer{type: :score, score: 1, probabilities: %{"1" => 0.9}}},
         {:invalid_answer, "urgency", :probabilities}},
        {%{good | "waiting" => %Answer{type: :noul, noul: 0.5, probabilities: %{true => 0.5}}},
         {:invalid_answer, "waiting", :probabilities}},
        {%{good | "verdict" => %Answer{type: :choice, choice: "stalled", confidence: "high"}},
         {:invalid_answer, "verdict", :confidence}},
        {%{good | "verdict" => %Answer{type: :choice, choice: "stalled", confidence: 2}},
         {:invalid_answer, "verdict", :confidence}}
      ]

      for {answers, detail} <- invalid do
        result = %Result{answers: answers, usage: %{"input_tokens" => 7}}

        assert {:error, %Error{kind: :invalid_response} = error} =
                 Decision.ask(selection(), "state", questions, reply: {:ok, result})

        assert error.details.reason == detail

        # The model still spent the tokens.
        assert %Usage{input_tokens: 7, model: "judge:4b", provider: "fake-local"} =
                 error.details.usage

        assert error.message =~ "Invalid decision response"
      end
    end

    test "rejects a malformed model or usage" do
      answers = %{"verdict" => %Answer{type: :choice, choice: "stalled"}}

      for {result, detail} <- [
            {%Result{answers: answers, usage: 42}, {:usage, 42}},
            {%Result{answers: answers, usage: "lots"}, {:usage, "lots"}},
            {%Result{answers: answers, model: 7}, {:model, 7}},
            {%Result{answers: answers, model: ""}, {:model, ""}}
          ] do
        assert {:error, %Error{kind: :invalid_response, details: %{reason: ^detail, usage: nil}}} =
                 Decision.ask(selection(), "state", [verdict_question()], reply: {:ok, result})
      end
    end

    test "validates before sending" do
      assert {:error, {:invalid_decision_request, :empty_state}} =
               Decision.ask(selection(), "  ", [verdict_question()], test_pid: self())

      refute_receive {:decide, _request, _opts}
    end
  end

  describe "Request.validate/1" do
    test "accepts every question type" do
      questions = [
        verdict_question(),
        Question.noul("stuck", "Is it stuck?"),
        Question.noul("waiting", "Is it waiting for input?", %{"true" => "prompt shown"}),
        Question.score("progress", "How much progress?", ["none", "some", "lots"])
      ]

      assert Request.validate(request(questions)) == :ok
      assert Request.validate(request(questions, %{"command" => "ls"})) == :ok
      assert Request.validate(request(questions, ["a", "b"])) == :ok
    end

    test "bounds the question count and requires unique names" do
      assert Request.validate(request([])) ==
               {:error, {:invalid_decision_request, {:question_count, 0}}}

      many =
        for index <- 1..65,
            do: Question.noul("q#{index}", "Question #{index}?")

      assert Request.validate(request(many)) ==
               {:error, {:invalid_decision_request, {:question_count, 65}}}

      assert Request.validate(request(Enum.take(many, 64))) == :ok

      assert Request.validate(request([verdict_question(), verdict_question()])) ==
               {:error, {:invalid_decision_request, {:duplicate_question, "verdict"}}}
    end

    test "bounds choice and score options" do
      one_option = Question.choice("c", "Pick", %{"only" => nil})
      too_many = Question.choice("c", "Pick", Map.new(1..25, &{"o#{&1}", nil}))
      max = Question.choice("c", "Pick", Map.new(1..24, &{"o#{&1}", nil}))
      one_level = Question.score("s", "Rate", ["low"])

      assert Request.validate(request([one_option])) ==
               {:error, {:invalid_decision_request, {:invalid_question, "c", {:option_count, 1}}}}

      assert Request.validate(request([too_many])) ==
               {:error,
                {:invalid_decision_request, {:invalid_question, "c", {:option_count, 25}}}}

      assert Request.validate(request([max])) == :ok

      assert Request.validate(request([one_level])) ==
               {:error, {:invalid_decision_request, {:invalid_question, "s", {:option_count, 1}}}}
    end

    test "rejects malformed questions" do
      cases = [
        {%Question{name: "", type: :choice, instructions: "x", criteria: %{"a" => nil}},
         {:invalid_question, "", :invalid_name}},
        {%Question{name: "q", type: :bogus, instructions: "x"},
         {:invalid_question, "q", {:invalid_type, :bogus}}},
        {%Question{name: "q", type: :noul, instructions: " "},
         {:invalid_question, "q", :invalid_instructions}},
        {Question.choice("q", "x", ["a", "b"]), {:invalid_question, "q", :invalid_criteria}},
        {Question.choice("q", "x", %{"a" => 1, "b" => nil}),
         {:invalid_question, "q", :invalid_criteria}},
        {Question.noul("q", "x", %{"maybe" => "?"}), {:invalid_question, "q", :invalid_criteria}},
        {Question.score("q", "x", ["low", ""]), {:invalid_question, "q", :invalid_criteria}},
        {:not_a_question, {:invalid_question, :not_a_question}}
      ]

      for {question, detail} <- cases do
        assert Request.validate(request([question])) ==
                 {:error, {:invalid_decision_request, detail}}
      end
    end

    test "requires a model and a non-empty, encodable state" do
      for state <- ["", "   ", %{}, []] do
        assert Request.validate(request([verdict_question()], state)) ==
                 {:error, {:invalid_decision_request, :empty_state}}
      end

      for state <- [nil, 42, %{"pid" => self()}, [{:a, 1}]] do
        assert Request.validate(request([verdict_question()], state)) ==
                 {:error, {:invalid_decision_request, :invalid_state}}
      end

      assert Request.validate(Request.new("state", [verdict_question()])) ==
               {:error, {:invalid_decision_request, :invalid_model}}

      assert Request.validate(:nope) == {:error, {:invalid_decision_request, :not_a_request}}
    end

    test "limits the encoded request to 64 KiB" do
      overhead =
        request([verdict_question()], "")
        |> Request.to_json_map()
        |> JSON.encode!()
        |> byte_size()

      fits = String.duplicate("a", Request.max_encoded_bytes() - overhead)
      assert Request.validate(request([verdict_question()], fits)) == :ok

      assert {:error, {:invalid_decision_request, {:request_too_large, bytes}}} =
               Request.validate(request([verdict_question()], fits <> "a"))

      assert bytes == Request.max_encoded_bytes() + 1
    end
  end

  test "to_json_map/1 encodes questions by name" do
    request =
      request([
        verdict_question(),
        Question.noul("stuck", "Is it stuck?"),
        Question.score("progress", "How much?", ["none", "lots"])
      ])

    assert Request.to_json_map(request) == %{
             "model" => "judge:4b",
             "state" => "state",
             "questions" => %{
               "verdict" => %{
                 "type" => "choice",
                 "instructions" => "Is the command stuck?",
                 "criteria" => %{"progressing" => "Output still advances", "stalled" => nil}
               },
               "stuck" => %{"type" => "noul", "instructions" => "Is it stuck?"},
               "progress" => %{
                 "type" => "score",
                 "instructions" => "How much?",
                 "criteria" => ["none", "lots"]
               }
             }
           }
  end
end
