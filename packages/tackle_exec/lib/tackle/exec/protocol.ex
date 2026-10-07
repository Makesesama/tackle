defmodule Tackle.Exec.Protocol do
  @moduledoc """
  Wire protocol between the trusted host and the jailed exec-server.

  Every frame is a single Erlang external term. The host sends requests; the
  exec-server sends one `{:hello, version}` frame followed by replies.

  ## Requests (host to jail)

      {:exec, id, %{argv: [binary], cwd: binary, env: [{binary, binary}], window: pos_integer}}
      {:signal, id, :term | :kill}
      {:grant, id, pos_integer}
      {:read, id, %{path: binary, offset: non_neg_integer, length: pos_integer}}
      {:write, id, %{path: binary, data: binary, mkdir_p: boolean, mode: :replace | :append | :create}}
      {:delete, id, %{path: binary}}
      {:stat, id, %{path: binary}}

  ## Messages (jail to host)

      {:hello, version}
      {:out, id, binary}
      {:exit, id, 0..255}
      {:ok, id, result}
      {:error, id, binary}

  `:exec` output is credit based: the exec-server may send at most `window`
  bytes of `:out` data plus whatever later `:grant` requests add. Errors are
  always binaries of at most 4096 bytes on the wire, so a reply can never
  require atoms that do not exist on the host; `error_reason/1` maps known
  POSIX codes back to atoms.

  ## Trust

  Messages from the jail are untrusted. `decode/1` rejects compressed terms,
  trailing bytes, and terms that would create atoms or external functions.
  `parse_message/1` and `parse_result/3` then accept only the closed shapes
  above, checking and bounding every field, so funs, PIDs, ports, references,
  and oversized integers are never accepted.

  Decoding happens before validation, and a term can take more memory than its
  encoding (a list of `[]` needs about 16 bytes per encoded byte), so hosts
  should keep the incoming frame limit well below their memory budget.
  """

  @version 1
  @max_error_bytes 4_096
  @max_file_size 0x7FFF_FFFF_FFFF_FFFF
  @max_mode 0o177777

  @posix_errors ~w(eacces eagain ebadf ebusy edquot eexist efbig eintr einval eio
                   eisdir eloop emfile emlink enametoolong enfile enodev enoent
                   enomem enospc enotdir enotempty enxio eperm epipe erofs espipe
                   etxtbsy exdev)
  @posix_atoms Map.new(@posix_errors, &{&1, String.to_atom(&1)})

  @file_types [:device, :directory, :other, :regular, :symlink]
  @signals [:term, :kill]
  @write_modes [:replace, :append, :create]

  @typedoc "Host-issued request identifier."
  @type id :: pos_integer()

  @typedoc "Supported signals for running commands."
  @type signal :: :term | :kill

  @typedoc "Requests sent from the host to the exec-server."
  @type request ::
          {:exec, id(),
           %{
             argv: [binary()],
             cwd: binary(),
             env: [{binary(), binary()}],
             window: pos_integer()
           }}
          | {:signal, id(), signal()}
          | {:grant, id(), pos_integer()}
          | {:read, id(), %{path: binary(), offset: non_neg_integer(), length: pos_integer()}}
          | {:write, id(),
             %{
               path: binary(),
               data: binary(),
               mkdir_p: boolean(),
               mode: :replace | :append | :create
             }}
          | {:delete, id(), %{path: binary()}}
          | {:stat, id(), %{path: binary()}}

  @typedoc "Messages sent from the exec-server to the host."
  @type message ::
          {:hello, integer()}
          | {:out, id(), binary()}
          | {:exit, id(), 0..255}
          | {:ok, id(), term()}
          | {:error, id(), binary()}

  @typedoc "Operations that receive a single `:ok` or `:error` reply."
  @type call_op :: :read | :write | :delete | :stat

  @doc "Returns the protocol version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the frame the exec-server sends first."
  @spec hello() :: {:hello, pos_integer()}
  def hello, do: {:hello, @version}

  @doc "Encodes a term as an external term binary without a length header."
  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)

  @doc "Encodes a term as a 4-byte big-endian length-prefixed frame."
  @spec encode_frame(term()) :: binary()
  def encode_frame(term) do
    payload = encode(term)
    <<byte_size(payload)::32, payload::binary>>
  end

  @doc """
  Decodes one untrusted frame.

  Rejects compressed terms (to avoid decompression bombs), trailing bytes, and
  anything `:erlang.binary_to_term/2` refuses in `:safe` mode.
  """
  @spec decode(binary()) ::
          {:ok, term()} | {:error, :compressed_term | :trailing_bytes | :invalid_term}
  def decode(<<131, 80, _rest::binary>>), do: {:error, :compressed_term}

  def decode(<<131, _rest::binary>> = frame) do
    case :erlang.binary_to_term(frame, [:safe, :used]) do
      {term, used} when used == byte_size(frame) -> {:ok, term}
      {_term, _used} -> {:error, :trailing_bytes}
    end
  rescue
    ArgumentError -> {:error, :invalid_term}
  end

  def decode(frame) when is_binary(frame), do: {:error, :invalid_term}

  @doc "Validates a message received from the exec-server."
  @spec parse_message(term()) :: {:ok, message()} | {:error, :invalid_message}
  def parse_message({:hello, version} = message) when is_integer(version), do: {:ok, message}

  def parse_message({:out, id, data} = message)
      when is_integer(id) and id > 0 and is_binary(data) and data != "",
      do: {:ok, message}

  def parse_message({:exit, id, status} = message)
      when is_integer(id) and id > 0 and is_integer(status) and status in 0..255,
      do: {:ok, message}

  def parse_message({:ok, id, _result} = message) when is_integer(id) and id > 0,
    do: {:ok, message}

  def parse_message({:error, id, reason} = message)
      when is_integer(id) and id > 0 and is_binary(reason) and
             byte_size(reason) <= @max_error_bytes,
      do: {:ok, message}

  def parse_message(_term), do: {:error, :invalid_message}

  @doc """
  Validates the result of a successful call operation against its request
  parameters.
  """
  @spec parse_result(call_op(), map(), term()) :: {:ok, term()} | {:error, :invalid_result}
  def parse_result(:read, %{length: length}, %{data: data, size: size, eof: eof} = result)
      when map_size(result) == 3 and is_binary(data) and byte_size(data) <= length and
             is_integer(size) and size in 0..@max_file_size and is_boolean(eof),
      do: {:ok, result}

  def parse_result(op, _params, nil) when op in [:write, :delete], do: {:ok, nil}

  def parse_result(:stat, _params, %{type: type, size: size, mode: mode} = result)
      when map_size(result) == 3 and type in @file_types and is_integer(size) and
             size in 0..@max_file_size and is_integer(mode) and mode in 0..@max_mode,
      do: {:ok, result}

  def parse_result(_op, _params, _result), do: {:error, :invalid_result}

  @doc "Validates a request before sending it or after receiving it."
  @spec parse_request(term()) :: {:ok, request()} | {:error, :invalid_request}
  def parse_request(
        {:exec, id, %{argv: argv, cwd: cwd, env: env, window: window} = params} = request
      )
      when map_size(params) == 4 and is_integer(window) and window > 0 do
    valid? =
      id?(id) and argv?(argv) and path?(cwd) and is_list(env) and Enum.all?(env, &env_entry?/1)

    if valid?, do: {:ok, request}, else: {:error, :invalid_request}
  end

  def parse_request({:signal, id, signal} = request) when signal in @signals,
    do: if(id?(id), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request({:grant, id, bytes} = request) when is_integer(bytes) and bytes > 0,
    do: if(id?(id), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request({:read, id, %{path: path, offset: offset, length: length} = params} = request)
      when map_size(params) == 3 and is_integer(offset) and offset >= 0 and is_integer(length) and
             length > 0,
      do: if(id?(id) and path?(path), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request(
        {:write, id, %{path: path, data: data, mkdir_p: mkdir_p, mode: mode} = params} = request
      )
      when map_size(params) == 4 and is_binary(data) and is_boolean(mkdir_p) and
             mode in @write_modes,
      do: if(id?(id) and path?(path), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request({:delete, id, %{path: path} = params} = request) when map_size(params) == 1,
    do: if(id?(id) and path?(path), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request({:stat, id, %{path: path} = params} = request) when map_size(params) == 1,
    do: if(id?(id) and path?(path), do: {:ok, request}, else: {:error, :invalid_request})

  def parse_request(_term), do: {:error, :invalid_request}

  @doc "Converts a wire error into an error reason, mapping known POSIX codes to atoms."
  @spec error_reason(binary()) :: atom() | binary()
  def error_reason(reason) when is_binary(reason), do: Map.get(@posix_atoms, reason, reason)

  @doc "Converts a local error reason into its wire representation, truncated to the limit."
  @spec wire_error(term()) :: binary()
  def wire_error(reason) when is_binary(reason), do: truncate(reason)
  def wire_error(reason) when is_atom(reason), do: reason |> Atom.to_string() |> truncate()
  def wire_error(reason), do: reason |> inspect() |> truncate()

  defp truncate(reason) when byte_size(reason) <= @max_error_bytes, do: reason
  defp truncate(reason), do: binary_part(reason, 0, @max_error_bytes)

  defp id?(id), do: is_integer(id) and id > 0

  defp argv?([_ | _] = argv), do: Enum.all?(argv, &arg?/1)
  defp argv?(_argv), do: false

  defp arg?(arg), do: is_binary(arg) and not String.contains?(arg, <<0>>)

  defp path?(path), do: arg?(path) and path != ""

  defp env_entry?({name, value}) when is_binary(name) and is_binary(value) do
    name != "" and String.valid?(name) and String.valid?(value) and
      not String.contains?(name, ["=", <<0>>]) and not String.contains?(value, <<0>>)
  end

  defp env_entry?(_entry), do: false
end
