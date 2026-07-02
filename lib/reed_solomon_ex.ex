defmodule ReedSolomonEx do
  # Above this parity, worst-case decode (parity/2 errors) can exceed the
  # ~1ms regular-scheduler budget on a 1 GHz in-order core, so it goes dirty.
  @dirty_parity_threshold 32

  # Batch slices sized so one NIF call stays under ~1ms on a 1 GHz in-order
  # core. Decoding is ~4x the work of encoding per codeword, hence the smaller
  # factor. At parity 8: encode 32 chunks/call, decode 8/call.
  @encode_batch_work_factor 256
  @correct_batch_work_factor 64
  @max_batch_slice 32

  @moduledoc """
  Reed-Solomon encoder/decoder wrapper using Rust NIF.

  Wraps the `reed-solomon` Rust crate to provide robust
  error-correcting codes for binary data. This library is suitable for
  transmitting binary packets over noisy links with optional parity.

  ## Examples

      iex> {:ok, codeword} = ReedSolomonEx.encode("hello", 4)
      iex> {:ok, original} = ReedSolomonEx.correct(codeword, 4)
      iex> original == "hello"
      true

  ## Schedulers

  Codewords are capped at 255 bytes (GF(2^8)), so a single encode or decode
  is far below the ~1ms threshold that warrants a dirty scheduler. Encoding
  always runs on a regular scheduler; decoding runs on a regular scheduler
  for parity sizes up to #{@dirty_parity_threshold} bytes and falls back to a
  dirty-CPU scheduler above that, where worst-case decode work on slow cores
  may exceed 1ms.

  This matters on targets where the dirty-CPU run queue is kept busy by
  other NIFs (e.g. ML inference): a sub-millisecond encode should not queue
  behind a 100ms+ dirty job.

  For many small chunks, prefer `encode_batch/3` / `correct_batch/3`, which
  amortize NIF call overhead by looping in Rust. The wrapper slices large
  batches so no single regular-scheduler call exceeds the ~1ms budget.
  """
  @version Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :reed_solomon_ex,
    crate: "reed_solomon_ex",
    base_url: "https://github.com/fermuch/reed_solomon_ex/releases/download/v#{@version}",
    force_build: System.get_env("REED_SOLOMON_EX_FORCE_BUILD") in ["1", "true"],
    version: @version,
    nif_versions: ~w(2.15 2.17),
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      arm-unknown-linux-gnueabihf
      riscv64gc-unknown-linux-gnu
      riscv64gc-unknown-linux-musl
      x86_64-apple-darwin
      x86_64-pc-windows-gnu
      x86_64-pc-windows-msvc
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    )

  @doc """
  Encodes a binary by appending N parity bytes for error correction.

  Runs on a regular scheduler: input is capped at 255 bytes total, so the
  work is always sub-millisecond.

  ## Parameters
  - `data`: binary to encode
  - `parity_bytes`: number of bytes to use as parity (must be >= 2)

  ## Returns
  - `{:ok, binary}` with appended parity
  - `{:error, reason}` on failure
  """
  @spec encode(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, any()}
  def encode(_data, _parity_bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encodes a binary by appending N parity bytes for error correction.
  As encode/2, except that it only returns the parity bytes.
  """
  @spec encode_ecc(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, any()}
  def encode_ecc(_data, _parity_bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encodes a list of binaries in a single NIF call per slice, appending
  `parity_bytes` of parity to each chunk.

  Equivalent to `Enum.map(chunks, &encode(&1, parity_bytes))` but far cheaper
  when encoding many small chunks: one NIF round-trip covers a whole slice of
  chunks and the Reed-Solomon generator polynomial is computed once.

  The chunk list is internally sliced so that no single NIF invocation
  exceeds the ~1ms regular-scheduler budget, even on slow cores. The slice
  size scales inversely with `parity_bytes` (32 chunks per call at parity 8)
  and can be overridden with the `:slice_size` option.

  ## Parameters
  - `chunks`: list of binaries to encode (each `byte_size(chunk) + parity_bytes <= 255`)
  - `parity_bytes`: number of bytes to use as parity (must be >= 2)
  - `opts`: `slice_size: pos_integer()` — chunks per NIF invocation

  ## Returns
  - `{:ok, [binary()]}` encoded codewords, in input order
  - `{:error, reason}` if any chunk is oversized (reports the failing chunk index)
  """
  @spec encode_batch([binary()], non_neg_integer(), keyword()) ::
          {:ok, [binary()]} | {:error, any()}
  def encode_batch(chunks, parity_bytes, opts \\ []) when is_list(chunks) do
    chunks
    |> Enum.chunk_every(slice_size(parity_bytes, @encode_batch_work_factor, opts))
    |> Enum.reduce_while({:ok, []}, fn slice, {:ok, acc} ->
      case encode_batch_nif(slice, parity_bytes) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, slices} -> {:ok, slices |> Enum.reverse() |> List.flatten()}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec correct(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, any()}
  def correct(codeword, parity_bytes), do: correct(codeword, parity_bytes, nil)

  @doc """
  Decode/correct a binary codeword and attempts to correct up to N/2 errors.

  Runs on a regular scheduler for `parity_bytes <= #{@dirty_parity_threshold}`,
  on a dirty-CPU scheduler above that.

  ## Parameters
  - `codeword`: binary of data + parity
  - `parity_bytes`: number of parity bytes originally used
  - `known_erasures`: offsets of known erasures (optional)

  ## Returns
  - `{:ok, original_data}` on success
  - `{:error, reason}` if the message cannot be corrected
  """
  @spec correct(binary(), non_neg_integer(), [byte()] | nil) ::
          {:ok, binary()} | {:error, any()}
  def correct(codeword, parity_bytes, known_erasures)
      when parity_bytes <= @dirty_parity_threshold,
      do: correct_small(codeword, parity_bytes, known_erasures)

  def correct(codeword, parity_bytes, known_erasures),
    do: correct_dirty(codeword, parity_bytes, known_erasures)

  @doc """
  Decodes/corrects a list of codewords in a single NIF call per slice.

  Unlike `encode_batch/3`, failures are per-codeword: a corrupted-beyond-repair
  codeword yields `:error` in its position without failing the batch.

  Known erasures are not supported in batch mode; use `correct/3` for
  codewords with known erasure positions.

  ## Parameters
  - `codewords`: list of binaries (data + parity each)
  - `parity_bytes`: number of parity bytes originally used
  - `opts`: `slice_size: pos_integer()` — codewords per NIF invocation

  ## Returns
  - `{:ok, results}` where `results` is a list of `{:ok, binary()} | :error`,
    in input order
  """
  @spec correct_batch([binary()], non_neg_integer(), keyword()) ::
          {:ok, [{:ok, binary()} | :error]}
  def correct_batch(codewords, parity_bytes, opts \\ [])

  def correct_batch(codewords, parity_bytes, opts)
      when is_list(codewords) and parity_bytes <= @dirty_parity_threshold do
    results =
      codewords
      |> Enum.chunk_every(slice_size(parity_bytes, @correct_batch_work_factor, opts))
      |> Enum.flat_map(&correct_batch_nif(&1, parity_bytes))

    {:ok, results}
  end

  def correct_batch(codewords, parity_bytes, _opts) when is_list(codewords) do
    results =
      Enum.map(codewords, fn codeword ->
        case correct_dirty(codeword, parity_bytes, nil) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> :error
        end
      end)

    {:ok, results}
  end

  @doc false
  @spec correct_err_count(binary(), non_neg_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, any()}
  def correct_err_count(codeword, parity_bytes),
    do: correct_err_count(codeword, parity_bytes, nil)

  @doc """
  Decode/Correct a binary codeword and attempts to correct up to N/2 errors.
  Same as `correct/2`, but returns the number of errors corrected.

  Runs on a regular scheduler for `parity_bytes <= #{@dirty_parity_threshold}`,
  on a dirty-CPU scheduler above that.

  ## Parameters
  - `codeword`: binary of data + parity
  - `parity_bytes`: number of parity bytes originally used
  - `known_erasures`: offsets of known erasures (optional)

  ## Returns
  - `{:ok, {original_data, err_count}}` on success
  - `{:error, reason}` if the message cannot be corrected
  """
  @spec correct_err_count(binary(), non_neg_integer(), [byte()] | nil) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, any()}
  def correct_err_count(codeword, parity_bytes, known_erasures)
      when parity_bytes <= @dirty_parity_threshold,
      do: correct_err_count_small(codeword, parity_bytes, known_erasures)

  def correct_err_count(codeword, parity_bytes, known_erasures),
    do: correct_err_count_dirty(codeword, parity_bytes, known_erasures)

  @doc "Check if a given codeword is corrupted (detectable by RS)."
  @spec is_corrupted(binary(), non_neg_integer()) :: {:ok, boolean()} | {:error, any()}
  def is_corrupted(_codeword, _parity_bytes), do: :erlang.nif_error(:nif_not_loaded)

  defp slice_size(parity_bytes, work_factor, opts) do
    Keyword.get(opts, :slice_size) ||
      work_factor |> div(max(parity_bytes, 1)) |> max(1) |> min(@max_batch_slice)
  end

  # NIF stubs; the *_dirty variants are DirtyCpu-scheduled in Rust.
  @doc false
  def correct_small(_codeword, _parity_bytes, _known_erasures),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def correct_dirty(_codeword, _parity_bytes, _known_erasures),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def correct_err_count_small(_codeword, _parity_bytes, _known_erasures),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def correct_err_count_dirty(_codeword, _parity_bytes, _known_erasures),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def encode_batch_nif(_chunks, _parity_bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def correct_batch_nif(_codewords, _parity_bytes), do: :erlang.nif_error(:nif_not_loaded)
end
