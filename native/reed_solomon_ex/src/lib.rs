use rustler::{Binary, Env, NewBinary};
use reed_solomon::{Encoder as RSEncoder, Decoder as RSDecoder};

rustler::init!("Elixir.ReedSolomonEx");

#[rustler::nif]
fn encode<'a>(env: Env<'a>, data: Binary<'a>, parity_bytes: usize) -> Result<Binary<'a>, String> {
    let encoder = RSEncoder::new(parity_bytes);
    let encoded = encoder.encode(data.as_slice());

    let mut binary = NewBinary::new(env, encoded.len());
    binary.as_mut_slice().copy_from_slice(&encoded);
    Ok(binary.into())
}

#[rustler::nif]
fn encode_ecc<'a>(env: Env<'a>, data: Binary<'a>, parity_byte: usize) -> Result<Binary<'a>, String> {
    let encoder = RSEncoder::new(parity_byte);
    let encoded = encoder.encode(data.as_slice());

    let mut binary = NewBinary::new(env, encoded.ecc().len());
    binary.as_mut_slice().copy_from_slice(encoded.ecc());
    Ok(binary.into())
}

#[rustler::nif]
fn correct<'a>(env: Env<'a>, codeword: Binary<'a>, parity_bytes: usize, erasures: Option<Vec<u8>>) -> Result<Binary<'a>, String> {
    let decoder = RSDecoder::new(parity_bytes);
    let corrected = decoder.correct(codeword.as_slice(), erasures.as_deref()).map_err(|_| "decode_failed".to_string())?;

    let mut binary = NewBinary::new(env, corrected.data().len());
    binary.as_mut_slice().copy_from_slice(corrected.data());
    Ok(binary.into())
}

#[rustler::nif]
fn is_corrupted(codeword: Binary, parity_bytes: usize) -> Result<bool, String> {
    let decoder = RSDecoder::new(parity_bytes);
    Ok(decoder.is_corrupted(&codeword))
}

#[rustler::nif]
fn correct_err_count<'a>(env: Env<'a>, codeword: Binary<'a>, parity_bytes: usize, erasures: Option<Vec<u8>>) -> Result<(Binary<'a>, usize), String> {
    let decoder = RSDecoder::new(parity_bytes);
    let (corrected, count) = decoder
        .correct_err_count(codeword.as_slice(), erasures.as_deref())
        .map_err(|_| "decode_failed".to_string())?;

    let mut binary = NewBinary::new(env, corrected.data().len());
    binary.as_mut_slice().copy_from_slice(corrected.data());

    Ok((binary.into(), count))
}
