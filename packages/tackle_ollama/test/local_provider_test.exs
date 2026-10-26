defmodule Tackle.Plugins.Ollama.LocalProviderTest do
  @moduledoc false
  # The default local `"ollama"` provider: keyless chat and System One decisions.
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Cancellation, Decision, LLM, Usage}
  alias Tackle.Lib.Decision.{Answer, Question, Result}
  alias Tackle.Lib.LLM.Error
  alias Tackle.Plugins.Ollama

  setup do
    previous = Application.get_env(:tackle_ollama, Ollama)

    Application.put_env(:tackle_ollama, Ollama,
      providers: %{
        "ollama" => %{
          "models" => ["qwen3:8b", "gpt-oss:20b"],
          "model_info" => %{"gpt-oss:20b" => %{"context_window" => 131_072}},
          "decision_models" => ["tev1:4b", "nimble"]
        }
      }
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tackle_ollama, Ollama, previous),
        else: Application.delete_env(:tackle_ollama, Ollama)
    end)

    :ok
  end

  describe "models" do
    test "come only from configuration" do
      settings = local_settings()
      assert Ollama.models(settings) == ["qwen3:8b", "gpt-oss:20b"]
      assert Ollama.decision_models(settings) == ["tev1:4b", "nimble"]
      assert Ollama.model_info("gpt-oss:20b", settings) == %{"context_window" => 131_072}
      assert Ollama.model_info("qwen3:8b", settings) == nil

      Application.delete_env(:tackle_ollama, Ollama)
      assert Ollama.models(local_settings()) == []
      assert Ollama.decision_models(local_settings()) == []
    end

    test "are selectable as chat and decision models" do
      assert {:ok, %{adapter: Ollama, provider_id: "ollama", model: "gpt-oss:20b"} = selection} =
               LLM.select([Ollama], "ollama/gpt-oss:20b")

      assert selection.model_info.context_window == 131_072

      assert {:ok, %Decision.Selection{adapter: Ollama, model: "tev1:4b", local: true}} =
               Decision.select([Ollama], "ollama/tev1:4b")

      assert {:error, {:unknown_decision_model, "ollama/qwen3:8b"}} =
               Decision.select([Ollama], "ollama/qwen3:8b")
    end

    test "malformed configured entries are reported by selection" do
      Application.put_env(:tackle_ollama, Ollama,
        providers: %{"ollama" => %{"models" => [""], "decision_models" => [:bad]}}
      )

      assert {:error, {:invalid_model_id, "ollama", ""}} = LLM.select([Ollama], "ollama/x")

      assert {:error, {:invalid_model_id, "ollama", :bad}} =
               Decision.select([Ollama], "ollama/x")
    end

    test "coexist with the default Ollama Cloud provider" do
      assert {:ok, %{provider_id: "ollama"}} = LLM.select([Ollama], "ollama/qwen3:8b")

      assert {:ok, %{provider_id: "ollama-cloud"}} =
               LLM.select([Ollama], "ollama-cloud/gpt-oss:120b")
    end
  end

  defmodule RecordingStore do
    @behaviour Tackle.Lib.CredentialStore
    @impl true
    def fetch(pid, namespace) do
      send(pid, {:fetch, namespace})
      {:ok, %{"api_key" => "stored"}}
    end

    @impl true
    def put(_ref, _namespace, _credentials), do: :ok
    @impl true
    def delete(_ref, _namespace), do: :ok
  end

  describe "chat" do
    test "uses the local endpoint without an API key and reports its own provider" do
      parent = self()

      request = fn options ->
        send(parent, {:request, options})
        {:ok, %{status: 200, body: reasoning_completion()}}
      end

      assert {:ok, result} =
               LLM.generate_with(selection("ollama/qwen3:8b"), nil,
                 messages: [%{role: :user, content: "hi"}],
                 request: request
               )

      assert result.provider == "ollama"
      assert result.data["content"] == "ok"
      assert result.provider_state["provider"] == "ollama"
      assert %Usage{input_tokens: 4, output_tokens: 1} = result.usage

      assert_receive {:request, options}
      assert options[:url] == "http://localhost:11434/v1/chat/completions"
      refute List.keyfind(options[:headers], "authorization", 0)

      assert {"user-agent", "tackle-ollama/" <> _} =
               List.keyfind(options[:headers], "user-agent", 0)
    end

    test "never reads credentials" do
      previous = System.get_env("OLLAMA_API_KEY")
      System.put_env("OLLAMA_API_KEY", "cloud-key")

      on_exit(fn ->
        if previous,
          do: System.put_env("OLLAMA_API_KEY", previous),
          else: System.delete_env("OLLAMA_API_KEY")
      end)

      request = fn options ->
        send(self(), {:headers, options[:headers]})
        {:ok, %{status: 200, body: reasoning_completion()}}
      end

      store = {RecordingStore, self()}

      assert {:ok, _} =
               Ollama.generate(nil, chat_opts(request, api_key: "key", credential_store: store))

      refute_received {:fetch, _}
      assert_received {:headers, headers}
      refute List.keyfind(headers, "authorization", 0)
    end

    test "replays reasoning only from its own provider state" do
      parent = self()

      request = fn options ->
        send(parent, {:body, JSON.decode!(options[:body])})
        {:ok, %{status: 200, body: reasoning_completion()}}
      end

      messages = fn provider ->
        [
          %{role: :user, content: "hi"},
          %{
            role: :assistant,
            content: "earlier",
            provider_state: %{"provider" => provider, "model" => "qwen3:8b", "reasoning" => "r"}
          },
          %{role: :user, content: "again"}
        ]
      end

      assert {:ok, _} =
               Ollama.generate(nil, chat_opts(request, messages: messages.("ollama")))

      assert_receive {:body, %{"messages" => [_, assistant, _]}}
      assert assistant["reasoning"] == "r"

      assert {:ok, _} =
               Ollama.generate(nil, chat_opts(request, messages: messages.("ollama-cloud")))

      assert_receive {:body, %{"messages" => [_, assistant, _]}}
      refute Map.has_key?(assistant, "reasoning")
    end

    test "resolves the base URL from options, provider settings, then configuration" do
      parent = self()

      request = fn options ->
        send(parent, {:url, options[:url]})
        {:ok, %{status: 200, body: reasoning_completion()}}
      end

      Application.put_env(:tackle_ollama, Ollama,
        providers: %{
          "ollama" => %{"models" => ["qwen3:8b"], "base_url" => "http://gpu:11434/v1/"}
        }
      )

      assert {:ok, _} = Ollama.generate(nil, chat_opts(request))
      assert_receive {:url, "http://gpu:11434/v1/chat/completions"}

      assert {:ok, _} = LLM.generate_with(selection("ollama/qwen3:8b"), nil, chat_opts(request))
      assert_receive {:url, "http://gpu:11434/v1/chat/completions"}

      settings = %{"base_url" => "http://box:1234/v1", "models" => ["qwen3:8b"]}

      assert {:ok, _} =
               Ollama.generate(nil, chat_opts(request, provider_settings: settings))

      assert_receive {:url, "http://box:1234/v1/chat/completions"}

      assert {:ok, _} =
               Ollama.generate(
                 nil,
                 chat_opts(request, provider_settings: settings, base_url: "http://explicit/v1")
               )

      assert_receive {:url, "http://explicit/v1/chat/completions"}

      assert {:error, {:invalid_provider_settings, "ollama", {"base_url", 42}}} =
               Ollama.generate(
                 nil,
                 chat_opts(request, provider_settings: %{settings | "base_url" => 42})
               )

      assert {:error, {:invalid_provider_settings, "ollama", :not_a_map}} =
               Ollama.generate(nil, chat_opts(request, provider_settings: "invalid"))

      assert {:error, {:invalid_base_url, ""}} =
               Ollama.generate(nil, chat_opts(request, base_url: ""))

      refute_received {:url, _}
    end

    test "synthesizes missing tool-call ids under its own provider id" do
      stream = fn _options, initial, callback ->
        wire =
          frame(%{
            "tool_calls" => [
              %{"index" => 0, "function" => %{"name" => "search", "arguments" => "{}"}}
            ]
          }) <> frame(%{}, "tool_calls") <> "data: [DONE]\n\n"

        {:cont, parser} = callback.(wire, %{status: 200}, initial)
        {:ok, %{status: 200}, parser}
      end

      assert {:ok, result} = Ollama.generate(nil, chat_opts(nil, stream: stream))
      assert [%{"id" => "ollama-generated-" <> _}] = result.data["tool_calls"]
    end

    test "rejects unconfigured models before HTTP" do
      request = fn _ -> flunk("unexpected HTTP request") end

      assert {:error, {:unsupported_model, "llama3"}} =
               Ollama.generate(nil, chat_opts(request, model: "llama3"))
    end
  end

  describe "decide" do
    test "posts typed questions to /systemone and normalizes every answer type" do
      parent = self()

      request = fn options ->
        send(parent, {:request, options})

        {:ok,
         %{
           status: 200,
           body:
             JSON.encode!(%{
               "model" => "tev1:4b",
               "answers" => %{
                 "verdict" => %{
                   "type" => "choice",
                   "choice" => "stalled",
                   "probabilities" => %{"progressing" => 0.07, "stalled" => 0.93},
                   "confidence" => 0.86
                 },
                 "waiting" => %{"type" => "noul", "noul" => 0.25},
                 "urgency" => %{
                   "type" => "score",
                   "score" => 0.83,
                   "legend" => %{"0" => "Routine", "1" => "Soon", "2" => "Immediate"},
                   "probabilities" => %{"0" => 0.3, "1" => 0.57, "2" => 0.13},
                   "confidence" => 0.4
                 }
               },
               "usage" => %{"input_tokens" => 174, "output_tokens" => 1}
             })
         }}
      end

      assert {:ok, selection} = Decision.select([Ollama], "ollama/tev1:4b")

      assert {:ok, %Result{} = result} =
               Decision.decide(selection, %{"command" => "make"}, questions(),
                 request: request,
                 receive_timeout: 5_000
               )

      assert result.model == "tev1:4b"
      assert %Usage{input_tokens: 174, output_tokens: 1} = result.usage

      assert %Answer{type: :choice, choice: "stalled", confidence: 0.86} =
               verdict = result.answers["verdict"]

      assert verdict.probabilities == %{"progressing" => 0.07, "stalled" => 0.93}
      assert Answer.choice_probability(verdict) == 0.93
      assert %Answer{type: :noul, noul: 0.25} = result.answers["waiting"]

      assert %Answer{type: :score, score: 0.83, probabilities: %{0 => 0.3, 1 => 0.57, 2 => 0.13}} =
               result.answers["urgency"]

      assert_receive {:request, options}
      assert options[:method] == :post
      assert options[:url] == "http://localhost:11434/v1/systemone"
      assert options[:receive_timeout] == 5_000
      assert options[:decode_body] == false
      refute List.keyfind(options[:headers], "authorization", 0)

      assert JSON.decode!(options[:body]) == %{
               "model" => "tev1:4b",
               "state" => %{"command" => "make"},
               "questions" => %{
                 "verdict" => %{
                   "type" => "choice",
                   "instructions" => "Is the command stuck?",
                   "criteria" => %{"progressing" => "Output advances", "stalled" => nil}
                 },
                 "waiting" => %{"type" => "noul", "instructions" => "Waiting for input?"},
                 "urgency" => %{
                   "type" => "score",
                   "instructions" => "How urgent?",
                   "criteria" => ["Routine", "Soon", "Immediate"]
                 }
               }
             }
    end

    test "derives a missing score from level probabilities" do
      answers = %{
        "urgency" => %{"type" => "score", "probabilities" => %{"0" => 0.5, "2" => 0.5}}
      }

      assert {:ok, %Result{answers: %{"urgency" => %Answer{score: 1.0}}}} =
               decide([Question.score("urgency", "How urgent?", ["Low", "Mid", "High"])],
                 request: respond(200, %{"answers" => answers})
               )
    end

    test "rejects missing, mistyped, and unknown answers" do
      choice = Question.choice("verdict", "Stuck?", %{"yes" => nil, "no" => nil})

      for {answers, detail} <- [
            {%{}, {:missing_answer, "verdict"}},
            {%{"verdict" => %{"type" => "noul", "noul" => 0.5}}, {:invalid_answer, "verdict"}},
            {%{"verdict" => %{"type" => "choice", "choice" => "maybe"}},
             {:unknown_choice, "verdict", "maybe"}}
          ] do
        assert {:error, {:invalid_decision_response, ^detail}} =
                 decide([choice], request: respond(200, %{"answers" => answers}))
      end

      assert {:error, {:invalid_decision_response, :missing_answers}} =
               decide([choice], request: respond(200, %{"model" => "tev1:4b"}))

      assert {:error, {:invalid_decision_response, :invalid_json}} =
               decide([choice], request: fn _ -> {:ok, %{status: 200, body: "not json"}} end)
    end

    test "reports server errors and transport failures" do
      assert {:error,
              %Error{
                kind: :invalid_request,
                status: 404,
                message:
                  "The provider rejected the request (HTTP 404): model \"tev1:4b\" not found"
              }} =
               decide(questions(),
                 request: respond(404, %{"error" => "model \"tev1:4b\" not found"})
               )

      assert {:error, %Error{kind: :server, status: 500, details: "boom"}} =
               decide(questions(), request: fn _ -> {:ok, %{status: 500, body: "boom"}} end)

      assert {:error, %Error{kind: :transport, details: :econnrefused}} =
               decide(questions(), request: fn _ -> {:error, :econnrefused} end)

      assert {:error, %Error{kind: :unknown, message: "The provider request failed: raised"}} =
               decide(questions(), request: fn _ -> raise "raised" end)
    end

    test "rejects unconfigured models and invalid requests before HTTP" do
      request = fn _ -> flunk("unexpected HTTP request") end
      [question | _] = questions()

      assert {:error, {:unsupported_model, "qwen3:8b"}} =
               Ollama.decide(Decision.Request.new("state", [question], "qwen3:8b"),
                 request: request
               )

      assert {:error, {:invalid_decision_request, :empty_state}} =
               Ollama.decide(Decision.Request.new(" ", [question], "tev1:4b"),
                 request: request
               )
    end

    test "honours cancellation before and during the request" do
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      parent = self()

      request = fn _options ->
        send(parent, {:started, self()})
        Process.sleep(:infinity)
      end

      task =
        Task.async(fn -> decide(questions(), request: request, cancellation_signal: signal) end)

      assert_receive {:started, request_pid}, 1_000
      ref = Process.monitor(request_pid)
      Cancellation.cancel(signal)
      assert {:error, :cancelled} = Task.await(task, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^request_pid, _reason}, 1_000

      assert {:error, :cancelled} =
               decide(questions(),
                 request: fn _ -> flunk("unexpected HTTP request") end,
                 cancellation_signal: signal
               )
    end

    test "returns the answer when the request completes before cancellation" do
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      [question | _] = questions()

      answers = %{"verdict" => %{"type" => "choice", "choice" => "progressing"}}

      assert {:ok, %Result{answers: %{"verdict" => %Answer{choice: "progressing"}}}} =
               decide([question],
                 request: respond(200, %{"answers" => answers}),
                 cancellation_signal: signal
               )
    end

    test "uses the real Req transport against a loopback System One server" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, port} = :inet.port(listener)
      parent = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          request = receive_headers(socket, "")
          [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
          [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
          body = receive_body(socket, body, String.to_integer(length))
          send(parent, {:request, headers, JSON.decode!(body)})

          response =
            JSON.encode!(%{
              "model" => "tev1:4b",
              "answers" => %{"waiting" => %{"type" => "noul", "noul" => 0.9}},
              "usage" => %{"input_tokens" => 9, "output_tokens" => 0}
            })

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n" <>
                response
            )

          :gen_tcp.close(socket)
        end)

      {:ok, provider} =
        Tackle.Lib.LLM.Provider.new("gpu-box", Ollama, %{
          "base_url" => "http://127.0.0.1:#{port}/v1",
          "decision_models" => ["tev1:4b"],
          "local" => true
        })

      assert {:ok, selection} = Decision.select([provider], "gpu-box/tev1:4b")

      assert {:ok, %Result{answers: %{"waiting" => %Answer{noul: 0.9}}}} =
               Decision.decide(
                 selection,
                 "command output",
                 [Question.noul("waiting", "Waiting for input?")],
                 []
               )

      assert_received {:request, headers, body}
      assert headers =~ "POST /v1/systemone"
      refute headers =~ ~r/authorization/i
      assert body["model"] == "tev1:4b"
      Task.await(server)
    end
  end

  defp selection(ref) do
    {:ok, selection} = LLM.select([Ollama], ref)
    selection
  end

  defp local_settings do
    {"ollama", settings} = List.keyfind(Ollama.default_providers(), "ollama", 0)
    settings
  end

  defp decide(questions, opts) do
    {:ok, selection} = Decision.select([Ollama], "ollama/tev1:4b")
    Decision.decide(selection, "command output", questions, opts)
  end

  defp questions do
    [
      Question.choice("verdict", "Is the command stuck?", %{
        "progressing" => "Output advances",
        "stalled" => nil
      }),
      Question.noul("waiting", "Waiting for input?"),
      Question.score("urgency", "How urgent?", ["Routine", "Soon", "Immediate"])
    ]
  end

  defp respond(status, body), do: fn _ -> {:ok, %{status: status, body: JSON.encode!(body)}} end

  defp chat_opts(request, extra \\ []) do
    Keyword.merge(
      [model: "qwen3:8b", messages: [%{role: :user, content: "hi"}], request: request],
      extra
    )
  end

  defp reasoning_completion do
    frame(%{"reasoning" => "thinking"}) <>
      frame(%{"content" => "ok"}, "stop") <>
      "data: " <>
      JSON.encode!(%{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 1}
      }) <>
      "\n\ndata: [DONE]\n\n"
  end

  defp frame(delta, finish \\ nil),
    do:
      "data: " <>
        JSON.encode!(%{"choices" => [%{"delta" => delta, "finish_reason" => finish}]}) <> "\n\n"

  defp receive_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, acc <> chunk)
    end
  end

  defp receive_body(_socket, acc, length) when byte_size(acc) >= length, do: acc

  defp receive_body(socket, acc, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    receive_body(socket, acc <> chunk, length)
  end
end
