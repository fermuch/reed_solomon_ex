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

    corrupted = encoded
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
end
