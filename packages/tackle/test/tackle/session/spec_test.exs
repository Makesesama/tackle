defmodule Tackle.Session.SpecTest do
  use ExUnit.Case, async: true

  alias Tackle.Session.Spec

  describe "storage" do
    test "accepts the home, environment, and journal timeout" do
      storage = [home: "/tmp/tackle", env: %{"TACKLE_HOME" => "/tmp/x"}, journal_timeout: 500]

      assert {:ok, %Spec{storage: ^storage}} = Spec.new(storage: storage)
      assert {:ok, %Spec{storage: []}} = Spec.new([])
    end

    test "refuses options that would reach the journal's internals" do
      for key <- [:path, :archived, :project_key, :force, :reclaim, :cwd, :repair] do
        assert {:error, {:unknown_storage_options, [^key]}} =
                 Spec.new(storage: [{key, true}, home: "/tmp/tackle"])
      end
    end

    test "refuses option values of the wrong type" do
      assert {:error, {:invalid_storage_option, :home, nil}} = Spec.new(storage: [home: nil])
      assert {:error, {:invalid_storage_option, :env, []}} = Spec.new(storage: [env: []])

      assert {:error, {:invalid_storage_option, :journal_timeout, 0}} =
               Spec.new(storage: [journal_timeout: 0])
    end

    test "refuses storage that is not a keyword list" do
      assert {:error, {:invalid_storage, %{home: "/tmp"}}} = Spec.new(storage: %{home: "/tmp"})
      assert {:error, {:invalid_storage, ["home"]}} = Spec.new(storage: ["home"])
    end

    test "is validated again when a spec struct is passed" do
      spec = %Spec{storage: [path: "/tmp/elsewhere.dlog"]}

      assert {:error, {:unknown_storage_options, [:path]}} = Spec.new(spec)
    end
  end
end
