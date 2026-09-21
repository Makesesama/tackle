ExUnit.start()

ExUnit.after_suite(fn _result ->
  case Application.get_env(:tackle, :auth_file) do
    path when is_binary(path) -> File.rm_rf(Path.dirname(path))
    _path -> :ok
  end
end)
