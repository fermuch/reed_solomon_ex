# ReedSolomonEx

> **Note:** This is a fork of [ewildgoose/rs_protect](https://github.com/ewildgoose/rs_protect/)
> with the intention to experiment with new approaches and extend platform support.

ReedSolomonEx is an Elixir wrapper around the `reed-solomon` Rust crate using Rustler.
It provides fast, pure-Rust Reed-Solomon encoding and decoding for binary data.
Protection is implemented on a per byte basis and an ECC/Parity code will be generated
of length N, which will protect and correct against up to N/2 errors or erasures in the
source. This makes it useful for protecting short binaries against corruption in transmission

## Differences from Upstream

This fork diverges from the original with the following goals:

- **Extended platform support** — Native builds for embedded targets including:
  - `aarch64` (ARM64 embedded devices)
  - `riscv64` (RISC-V platforms)
- **Experimental features** — A playground for testing new approaches and optimizations
- **Nerves-friendly** — Designed to work seamlessly with [Nerves](https://nerves-project.org/) embedded Elixir projects

## Features
- Encode flat binary messages with added parity bytes
- Decode and correct up to `floor(parity_bytes / 2)` corrupted bytes with correct/2, correct/3
- Detect uncorrectable errors
- Get the number of corrections made with correct_err_count/2, correct_err_count/3
- Detect whether a message is corrupted with is_corrupted/1
- Batch encode/decode many chunks per NIF call with encode_batch/3, correct_batch/3

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:reed_solomon_ex, "~> 0.2"}
  ]
end
```

## Usage

```elixir
iex> data = <<1, 2, 3, 4, 5>>
iex> {:ok, encoded} = ReedSolomonEx.encode(data, 4)
iex> ReedSolomonEx.is_corrupted(encoded, 4)
{:ok, false}
iex> {:ok, decoded} = ReedSolomonEx.correct(encoded, 4)
decoded == data

iex> corrupted = :binary.replace(encoded, <<2>>, <<42>>, global: false)
iex> ReedSolomonEx.is_corrupted(corrupted, 4)
{:ok, true}
iex> {:ok, {recovered, count}} = ReedSolomonEx.correct_err_count(corrupted, 4)
{:ok, {^data, 1}}
```

### Batch API

When encoding many small chunks (e.g. framing a large payload), use
`encode_batch/3` to amortize NIF call overhead — one NIF call encodes a whole
slice of chunks and the generator polynomial is computed once:

```elixir
{:ok, codewords} = ReedSolomonEx.encode_batch(chunks, 8)

# results is a list of {:ok, data} | :error, one per codeword
{:ok, results} = ReedSolomonEx.correct_batch(codewords, 8)
```

Batches are internally sliced so no single NIF invocation exceeds the ~1ms
regular-scheduler budget, even on slow embedded cores. Pass `slice_size: n`
to tune the slicing for your hardware.

## Scheduler Behavior

Reed-Solomon codewords are capped at 255 bytes, so individual operations are
sub-millisecond even on slow cores. As of v0.2.0:

- `encode/2`, `encode_ecc/2`, `encode_batch/3`, `is_corrupted/2` and batch
  slices always run on **regular schedulers**.
- `correct/2,3`, `correct_err_count/2,3` run on regular schedulers for
  `parity_bytes <= 32` and on **dirty-CPU schedulers** above that, where
  worst-case decode work on a ~1 GHz in-order core can exceed 1ms.

This matters on embedded targets where dirty-CPU schedulers are saturated by
other long-running NIFs (e.g. ML inference): before v0.2.0 every call was
dirty-scheduled and a sub-millisecond encode could wait behind a 100ms+
inference job.

## Dynamic Parity Strategy

```elixir
def choose_parity(bytes) when byte_size(bytes) > 80, do: 16
def choose_parity(_), do: 4
```

## Development

This project uses [devenv](https://devenv.sh/) for development environment setup.

```bash
# Enter the development shell
devenv shell

# Or use direnv for automatic shell activation
direnv allow
```

### Building

```bash
# Force local build (for development)
REED_SOLOMON_EX_FORCE_BUILD=1 mix compile

# Run tests
mix test
```
