defmodule ReedSolomonExTest do
  use ExUnit.Case, async: true

  test "encode and decode without errors" do
    data = <<10, 20, 30, 40>>
    parity = 4
    assert {:ok, enc} = ReedSolomonEx.encode(data, parity)
    assert byte_size(enc) == byte_size(data) + parity
    assert {:ok, dec} = ReedSolomonEx.correct(enc, parity, nil)
    assert dec == data
  end

  test "corrects single error" do
    data = <<1, 2, 3, 4, 5, 6, 7>>
    parity = 6
    {:ok, encoded} = ReedSolomonEx.encode(data, parity)
    <<prefix::binary-size(3), _, suffix::binary>> = encoded
    corrupted = prefix <> <<0xFF>> <> suffix
    assert {:ok, recovered} = ReedSolomonEx.correct(corrupted, parity, nil)
    assert recovered == data
  end

  test "fails to decode if too many errors" do
    data = <<9, 8, 7, 6, 5, 4, 3, 2>>
    parity = 4
    {:ok, encoded} = ReedSolomonEx.encode(data, parity)

    corrupted =
      encoded
      |> :binary.bin_to_list()
      |> Enum.map(fn byte -> Bitwise.bxor(byte, 0xFF) end)
      |> :binary.list_to_bin()

    assert {:error, _} = ReedSolomonEx.correct(corrupted, parity, nil)
  end

  test "detects corruption with is_corrupted/2" do
    data = <<0, 1, 2, 3>>
    parity = 4
    {:ok, encoded} = ReedSolomonEx.encode(data, parity)
    assert {:ok, false} = ReedSolomonEx.is_corrupted(encoded, parity)

    corrupted = :binary.replace(encoded, <<1>>, <<42>>)
    assert {:ok, true} = ReedSolomonEx.is_corrupted(corrupted, parity)
  end

  test "returns correction count with decode_err_count/3" do
    data = "abcde"
    parity = 6
    {:ok, codeword} = ReedSolomonEx.encode(data, parity)
    <<p1::binary-size(2), _, rest::binary>> = codeword
    corrupted = p1 <> <<0xFF>> <> rest

    assert {:ok, {decoded, count}} = ReedSolomonEx.correct_err_count(corrupted, parity, nil)
    assert decoded == data
    assert count == 1
  end

  test "decode with known erasure" do
    data = "abcdef"
    parity = 2
    {:ok, codeword} = ReedSolomonEx.encode(data, parity)
    # Simulate corruption in the third byte
    <<p1::binary-size(2), _, rest::binary>> = codeword
    corrupted = p1 <> <<0xFF>> <> rest

    assert {:ok, recovered} = ReedSolomonEx.correct(corrupted, parity, [2])
    assert recovered == data
  end

  test "decode_err_count with known erasure" do
    data = "xyz123"
    parity = 4
    {:ok, codeword} = ReedSolomonEx.encode(data, parity)
    # Simulate corruption in the first byte
    <<_, rest::binary>> = codeword
    corrupted = <<0x00>> <> rest

    assert {:ok, {decoded, errs}} = ReedSolomonEx.correct_err_count(corrupted, parity, [0])
    assert decoded == data
    assert errs == 1
  end

  test "returns error when data + parity exceeds 255 bytes" do
    # 256 bytes data + 4 parity = 260 bytes (exceeds 255 limit)
    data = :binary.copy(<<0>>, 256)
    assert {:error, msg} = ReedSolomonEx.encode(data, 4)
    assert msg =~ "cannot exceed 255"
  end

  test "encode succeeds at maximum valid size" do
    # 251 bytes data + 4 parity = 255 bytes (exactly at limit)
    data = :binary.copy(<<0>>, 251)
    assert {:ok, encoded} = ReedSolomonEx.encode(data, 4)
    assert byte_size(encoded) == 255
  end

  test "wire format matches reference vector byte-for-byte" do
    # Reference vector from the reed-solomon crate's own test suite.
    data = :binary.list_to_bin(Enum.to_list(0..29))
    ecc = <<99, 26, 219, 193, 9, 94, 186, 143>>

    assert {:ok, encoded} = ReedSolomonEx.encode(data, 8)
    assert encoded == data <> ecc
    assert {:ok, ^ecc} = ReedSolomonEx.encode_ecc(data, 8)
  end

  describe "encode_batch/3" do
    test "matches per-call encode byte-for-byte, in order" do
      # 433 x 246B spans many internal slices, so ordering across slices is covered
      chunks = for _ <- 1..433, do: :crypto.strong_rand_bytes(246)

      assert {:ok, batch} = ReedSolomonEx.encode_batch(chunks, 8)
      assert batch == encode_each(chunks, 8)
    end

    test "handles variable-size chunks and empty list" do
      chunks = for size <- [0, 1, 100, 247], do: :crypto.strong_rand_bytes(size)
      assert {:ok, batch} = ReedSolomonEx.encode_batch(chunks, 8)
      assert Enum.map(batch, &byte_size/1) == [8, 9, 108, 255]

      assert {:ok, []} = ReedSolomonEx.encode_batch([], 8)
    end

    test "reports the failing chunk index on oversized input" do
      chunks = [<<1, 2, 3>>, :binary.copy(<<0>>, 250), <<4, 5>>]
      assert {:error, msg} = ReedSolomonEx.encode_batch(chunks, 8)
      assert msg =~ "chunk 1"
      assert msg =~ "cannot exceed 255"
    end

    test "respects :slice_size option" do
      chunks = for _ <- 1..10, do: :crypto.strong_rand_bytes(50)
      assert {:ok, batch} = ReedSolomonEx.encode_batch(chunks, 4, slice_size: 3)
      assert batch == encode_each(chunks, 4)
    end
  end

  describe "correct_batch/3" do
    test "roundtrips a batch, correcting errors per codeword" do
      data = for _ <- 1..100, do: :crypto.strong_rand_bytes(246)
      {:ok, codewords} = ReedSolomonEx.encode_batch(data, 8)

      corrupted =
        Enum.map(codewords, fn <<first, rest::binary>> ->
          <<Bitwise.bxor(first, 0xFF), rest::binary>>
        end)

      assert {:ok, results} = ReedSolomonEx.correct_batch(corrupted, 8)
      assert results == Enum.map(data, &{:ok, &1})
    end

    test "yields :error per unrecoverable codeword without failing the batch" do
      {:ok, [good]} = ReedSolomonEx.encode_batch(["hello"], 4)

      # Same corruption the "too many errors" test proves unrecoverable.
      {:ok, encoded} = ReedSolomonEx.encode(<<9, 8, 7, 6, 5, 4, 3, 2>>, 4)

      garbage =
        encoded
        |> :binary.bin_to_list()
        |> Enum.map(fn byte -> Bitwise.bxor(byte, 0xFF) end)
        |> :binary.list_to_bin()

      too_short = <<1, 2>>

      assert {:ok, [{:ok, "hello"}, :error, :error]} =
               ReedSolomonEx.correct_batch([good, garbage, too_short], 4)
    end
  end

  test "parity above the dirty threshold dispatches to dirty NIFs and roundtrips" do
    data = :binary.copy(<<7>>, 100)
    parity = 128
    {:ok, codeword} = ReedSolomonEx.encode(data, parity)

    <<_, rest::binary>> = codeword
    corrupted = <<0xFF>> <> rest

    assert {:ok, ^data} = ReedSolomonEx.correct(corrupted, parity)
    assert {:ok, {^data, 1}} = ReedSolomonEx.correct_err_count(corrupted, parity, nil)
    assert {:ok, [{:ok, ^data}]} = ReedSolomonEx.correct_batch([corrupted], parity)
  end

  test "correct returns error for codeword shorter than parity" do
    assert {:error, _} = ReedSolomonEx.correct(<<1, 2>>, 4)
    assert {:error, _} = ReedSolomonEx.correct_err_count(<<1, 2>>, 4)
  end

  defp encode_each(chunks, parity) do
    Enum.map(chunks, fn chunk ->
      {:ok, encoded} = ReedSolomonEx.encode(chunk, parity)
      encoded
    end)
  end
end
