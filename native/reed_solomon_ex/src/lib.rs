use reed_solomon::{Decoder as RSDecoder, Encoder as RSEncoder};
use rustler::types::atom;
use rustler::{Binary, Encoder, Env, NewBinary, Term};
use std::sync::OnceLock;

rustler::init!("Elixir.ReedSolomonEx");

const MAX_CODEWORD_SIZE: usize = 255;

// Encoder::new rebuilds the generator polynomial (O(parity^2)) on every call,
// so build each one once. Parity is bounded by the codeword size.
static ENCODERS: [OnceLock<RSEncoder>; MAX_CODEWORD_SIZE + 1] =
    [const { OnceLock::new() }; MAX_CODEWORD_SIZE + 1];

fn cached_encoder(parity_bytes: usize) -> &'static RSEncoder {
    ENCODERS[parity_bytes].get_or_init(|| RSEncoder::new(parity_bytes))
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

fn check_size(data_len: usize, parity_bytes: usize) -> Result<(), String> {
    if data_len + parity_bytes > MAX_CODEWORD_SIZE {
        return Err(format!(
            "data + parity cannot exceed {} bytes (got {} + {} = {})",
            MAX_CODEWORD_SIZE,
            data_len,
            parity_bytes,
            data_len + parity_bytes
        ));
    }
    Ok(())
}

fn check_codeword(len: usize, parity_bytes: usize) -> Result<(), String> {
    if len > MAX_CODEWORD_SIZE {
        return Err(format!(
            "codeword cannot exceed {} bytes (got {})",
            MAX_CODEWORD_SIZE, len
        ));
    }
    if len < parity_bytes {
        return Err("codeword shorter than parity".to_string());
    }
    Ok(())
}

// Codewords are capped at 255 bytes, so encoding is always sub-millisecond:
// it runs on regular schedulers where it cannot queue behind long-running
// dirty jobs. Decode cost grows with parity, so the Elixir wrapper dispatches
// to the *_dirty variants above a parity threshold.

#[rustler::nif]
fn encode<'a>(env: Env<'a>, data: Binary<'a>, parity_bytes: usize) -> Result<Binary<'a>, String> {
    check_size(data.len(), parity_bytes)?;
    Ok(to_binary(
        env,
        &cached_encoder(parity_bytes).encode(data.as_slice()),
    ))
}

#[rustler::nif]
fn encode_ecc<'a>(
    env: Env<'a>,
    data: Binary<'a>,
    parity_bytes: usize,
) -> Result<Binary<'a>, String> {
    check_size(data.len(), parity_bytes)?;
    let encoded = cached_encoder(parity_bytes).encode(data.as_slice());
    Ok(to_binary(env, encoded.ecc()))
}

#[rustler::nif]
fn encode_batch_nif<'a>(
    env: Env<'a>,
    chunks: Vec<Binary<'a>>,
    parity_bytes: usize,
) -> Result<Vec<Binary<'a>>, String> {
    check_size(0, parity_bytes)?;
    let encoder = cached_encoder(parity_bytes);
    chunks
        .iter()
        .enumerate()
        .map(|(i, chunk)| {
            check_size(chunk.len(), parity_bytes).map_err(|e| format!("chunk {}: {}", i, e))?;
            Ok(to_binary(env, &encoder.encode(chunk.as_slice())))
        })
        .collect()
}

fn do_correct<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<Binary<'a>, String> {
    check_codeword(codeword.len(), parity_bytes)?;
    let corrected = RSDecoder::new(parity_bytes)
        .correct(codeword.as_slice(), erasures.as_deref())
        .map_err(|_| "decode_failed".to_string())?;
    Ok(to_binary(env, corrected.data()))
}

#[rustler::nif]
fn correct_small<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<Binary<'a>, String> {
    do_correct(env, codeword, parity_bytes, erasures)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn correct_dirty<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<Binary<'a>, String> {
    do_correct(env, codeword, parity_bytes, erasures)
}

#[rustler::nif]
fn correct_batch_nif<'a>(
    env: Env<'a>,
    codewords: Vec<Binary<'a>>,
    parity_bytes: usize,
) -> Vec<Term<'a>> {
    let decoder = RSDecoder::new(parity_bytes);
    codewords
        .iter()
        .map(|codeword| {
            if check_codeword(codeword.len(), parity_bytes).is_err() {
                return atom::error().encode(env);
            }
            match decoder.correct(codeword.as_slice(), None) {
                Ok(corrected) => (atom::ok(), to_binary(env, corrected.data())).encode(env),
                Err(_) => atom::error().encode(env),
            }
        })
        .collect()
}

fn do_correct_err_count<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<(Binary<'a>, usize), String> {
    check_codeword(codeword.len(), parity_bytes)?;
    let (corrected, count) = RSDecoder::new(parity_bytes)
        .correct_err_count(codeword.as_slice(), erasures.as_deref())
        .map_err(|_| "decode_failed".to_string())?;
    Ok((to_binary(env, corrected.data()), count))
}

#[rustler::nif]
fn correct_err_count_small<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<(Binary<'a>, usize), String> {
    do_correct_err_count(env, codeword, parity_bytes, erasures)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn correct_err_count_dirty<'a>(
    env: Env<'a>,
    codeword: Binary<'a>,
    parity_bytes: usize,
    erasures: Option<Vec<u8>>,
) -> Result<(Binary<'a>, usize), String> {
    do_correct_err_count(env, codeword, parity_bytes, erasures)
}

#[rustler::nif]
fn is_corrupted(codeword: Binary, parity_bytes: usize) -> Result<bool, String> {
    if codeword.len() > MAX_CODEWORD_SIZE {
        return Err(format!(
            "codeword cannot exceed {} bytes (got {})",
            MAX_CODEWORD_SIZE,
            codeword.len()
        ));
    }
    Ok(RSDecoder::new(parity_bytes).is_corrupted(&codeword))
}
