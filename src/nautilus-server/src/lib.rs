// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Nautilus FFI library
//!
//! Minimal, general-purpose FFI for hosts like Bun/JS:
//! - Generate ephemeral Ed25519 keypair.
//! - Get public key (hex).
//! - Get Nitro Enclave attestation bound to public key.
//! - Sign arbitrary bytes as IntentMessage, returning JSON or BCS+signature.
//!
//! Usage order and memory:
//! 1) `nautilus_generate_ed25519_keypair` → keypair pointer
//! 2) `nautilus_get_public_key_hex` / `nautilus_get_attestation` (optional)
//! 3) `nautilus_sign_intent_message_json` or `nautilus_sign_intent_message_bcs`
//! 4) `nautilus_free_cstr` on any returned C string exactly once
//! 5) `nautilus_free_keypair` exactly once at the end
//!
//! Safety:
//! - Pointers and lengths must be valid; otherwise undefined behavior.
//! - Returned C strings are owned by Rust; free via `nautilus_free_cstr` once.
//! - Do not double-free; do not free with other functions.
//! - The keypair pointer is opaque; only use with these FFI functions.
use fastcrypto::ed25519::Ed25519KeyPair;
use fastcrypto::encoding::{Encoding, Hex};
use fastcrypto::traits::{KeyPair, Signer, ToFromBytes};
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CString};

// FFI-only crate: application modules removed.

#[repr(C)]
pub struct FfiKeyPair {
    inner: Ed25519KeyPair,
}

/// Generate a new ephemeral Ed25519 keypair and return an opaque pointer.
/// Caller must call `nautilus_free_keypair(ptr)` once to release memory.
#[no_mangle]
pub extern "C" fn nautilus_generate_ed25519_keypair() -> *mut FfiKeyPair {
    let kp = Ed25519KeyPair::generate(&mut rand::thread_rng());
    Box::into_raw(Box::new(FfiKeyPair { inner: kp }))
}

/// Free a previously returned keypair pointer.
/// Safe to call with NULL pointer (no-op). Do not double-free.
#[no_mangle]
pub extern "C" fn nautilus_free_keypair(ptr: *mut FfiKeyPair) {
    if !ptr.is_null() {
        unsafe { Box::from_raw(ptr) };
    }
}

/// Convert a Rust `String` into a raw C string (caller must free).
fn to_cstr(s: String) -> *mut c_char {
    CString::new(s).unwrap().into_raw()
}

/// Free a C string previously returned by this library.
/// Safe to call with NULL pointer (no-op). Only free once per returned string.
#[no_mangle]
pub extern "C" fn nautilus_free_cstr(s: *mut c_char) {
    if !s.is_null() {
        unsafe { let _ = CString::from_raw(s); }
    }
}

/// Return the hex-encoded Ed25519 public key for the given keypair pointer.
/// Returns a newly allocated C string; caller must free via `nautilus_free_cstr`.
#[no_mangle]
pub extern "C" fn nautilus_get_public_key_hex(ptr: *mut FfiKeyPair) -> *mut c_char {
    let pk = unsafe { (&*ptr).inner.public() };
    to_cstr(Hex::encode(pk.as_bytes()))
}

/// Request a Nitro Enclave attestation document committed to the keypair public key.
/// Returns the attestation document as hex (newly allocated C string; free with `nautilus_free_cstr`).
/// On error, returns an empty string.
#[no_mangle]
pub extern "C" fn nautilus_get_attestation(ptr: *mut FfiKeyPair) -> *mut c_char {
    let pk = unsafe { (&*ptr).inner.public() };
    let fd = nsm_api::driver::nsm_init();
    let request = nsm_api::api::Request::Attestation {
        user_data: None,
        nonce: None,
        public_key: Some(serde_bytes::ByteBuf::from(pk.as_bytes().to_vec())),
    };
    let response = nsm_api::driver::nsm_process_request(fd, request);
    match response {
        nsm_api::api::Response::Attestation { document } => {
            nsm_api::driver::nsm_exit(fd);
            to_cstr(Hex::encode(document))
        }
        _ => {
            nsm_api::driver::nsm_exit(fd);
            to_cstr(String::new())
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum IntentScope {
    ProcessData = 0,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct IntentMessage<T: Serialize> {
    pub intent: IntentScope,
    pub timestamp_ms: u64,
    pub data: T,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct IntentMessageBytes {
    pub intent: IntentScope,
    pub timestamp_ms: u64,
    pub data: serde_bytes::ByteBuf,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ProcessedDataResponse<T> {
    pub response: T,
    pub signature: String,
}

fn to_signed_response<T: Serialize + Clone>(
    kp: &Ed25519KeyPair,
    payload: T,
    timestamp_ms: u64,
    intent: IntentScope,
) -> ProcessedDataResponse<IntentMessage<T>> {
    let intent_msg = IntentMessage {
        intent,
        timestamp_ms,
        data: payload.clone(),
    };
    let signing_payload = bcs::to_bytes(&intent_msg).expect("bcs serialize");
    let sig = kp.sign(&signing_payload);
    ProcessedDataResponse {
        response: intent_msg,
        signature: Hex::encode(sig),
    }
}

/// Sign an intent message whose data field is arbitrary bytes (passed by pointer/length).
/// Returns JSON: `{ response: { intent, timestamp_ms, data: <base64> }, signature: <hex> }`.
/// Caller must free the returned C string via `nautilus_free_cstr`.
///
/// Parameters:
/// - `ptr`: keypair pointer from `nautilus_generate_ed25519_keypair`.
/// - `payload_ptr` / `payload_len`: raw bytes to include in the message.
/// - `timestamp_ms`: UNIX epoch in milliseconds.
/// - `intent`: intent scope as `u8` (current: `0` = ProcessData; future-safe).
///
/// Safety: `payload_ptr` must point to `payload_len` bytes; `ptr` must be non-NULL.
#[no_mangle]
pub extern "C" fn nautilus_sign_intent_message_json(
    ptr: *mut FfiKeyPair,
    payload_ptr: *const u8,
    payload_len: usize,
    timestamp_ms: u64,
    intent: u8,
) -> *mut c_char {
    let payload = unsafe { std::slice::from_raw_parts(payload_ptr, payload_len) }.to_vec();
    let intent_scope = match intent { 0 => IntentScope::ProcessData, _ => IntentScope::ProcessData };
    let intent_msg = IntentMessageBytes {
        intent: intent_scope.clone(),
        timestamp_ms,
        data: serde_bytes::ByteBuf::from(payload.clone()),
    };
    let signing_payload = bcs::to_bytes(&IntentMessage { intent: intent_scope, timestamp_ms, data: payload })
        .expect("bcs serialize");
    let sig = unsafe { (&*ptr).inner.sign(&signing_payload) };
    let resp = ProcessedDataResponse {
        response: intent_msg,
        signature: Hex::encode(sig),
    };
    to_cstr(serde_json::to_string(&resp).unwrap())
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct SignedBcsResponse {
    pub intent_message_bcs: String,
    pub signature: String,
}

/// Sign an intent message and return the BCS-encoded message and signature as hex strings.
/// Useful when the consumer needs raw BCS to submit on-chain or to other runtimes.
/// Caller must free the returned C string via `nautilus_free_cstr`.
///
/// Parameters are identical to `nautilus_sign_intent_message_json`.
///
/// Safety: `payload_ptr` must point to `payload_len` bytes; `ptr` must be non-NULL.
#[no_mangle]
pub extern "C" fn nautilus_sign_intent_message_bcs(
    ptr: *mut FfiKeyPair,
    payload_ptr: *const u8,
    payload_len: usize,
    timestamp_ms: u64,
    intent: u8,
) -> *mut c_char {
    let payload = unsafe { std::slice::from_raw_parts(payload_ptr, payload_len) }.to_vec();
    let intent_scope = match intent { 0 => IntentScope::ProcessData, _ => IntentScope::ProcessData };
    let intent_msg = IntentMessage { intent: intent_scope, timestamp_ms, data: payload };
    let signing_payload = bcs::to_bytes(&intent_msg).expect("bcs serialize");
    let sig = unsafe { (&*ptr).inner.sign(&signing_payload) };
    let resp = SignedBcsResponse {
        intent_message_bcs: Hex::encode(signing_payload),
        signature: Hex::encode(sig),
    };
    to_cstr(serde_json::to_string(&resp).unwrap())
}

// FFI-only: no error type exported.
