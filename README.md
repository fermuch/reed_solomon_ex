# ReedSolomonEx

ReedSolomonEx is an Elixir wrapper around the `reed-solomon` Rust crate using Rustler.
It provides fast, pure-Rust Reed-Solomon encoding and decoding for binary data.
Protection is implemented on a per byte basis and an ECC/Parity code will be generated
of length N, which will protect and correct against up to N/2 errors or erasures in the
source. This makes it useful for protecting short binaries against corruption in transmission

## Features
- Encode flat binary messages with added parity bytes
- Decode and correct up to `floor(parity_bytes / 2)` corrupted bytes with correct/2, correct/3
- Detect uncorrectable errors
- Get the number of corrections made with correct_err_count/2, correct_err_count/3
- Detect whether a message is corrupted with is_corrupted/1

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:reed_solomon_ex, "~> 0.1"}
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
