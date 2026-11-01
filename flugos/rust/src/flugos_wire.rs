//! `src/flugos_wire.rs`: Zero-Copy `bytemuck` Packet & Branchless IMA-ADPCM in `.iram1`
//!
//! Review Fix #1:
//!   - Every field in `FlugPacket` (`u16` at 0, `u8` at 2, `u8` at 3, `u16` at 4,
//!     `i16` at 6, `i8` at 8, `u8` at 9, `[u8; 160]` at 10) is naturally aligned
//!     with zero implicit padding (`size_of::<FlugPacket>() == 170` bytes <= 250B).
//!   - Using `#[repr(C)]` instead of `#[repr(C, packed)]` preserves the exact
//!     170-byte wire layout while satisfying `bytemuck::Pod` alignment invariants
//!     and eliminating unaligned reference UB (`E0793`).

use bytemuck::{Pod, Zeroable};

pub const FLUGOS_MAGIC: u16 = 0xF106;
pub const ADPCM_SAMPLES: usize = 320;
pub const ADPCM_BYTES: usize = 160;
pub const BCAST_MAC: [u8; 6] = [0xFF; 6];

#[repr(u8)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum PktType {
    AudioAdpcm = 0x01,
    AudioEof   = 0x02,
    TextUtter  = 0x03,
    EnvTelem   = 0x04,
}

#[repr(u8)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Lang {
    En = 0,
    Ja = 1,
    Hu = 2,
}

/// 170-byte wire frame (10-byte header + 160-byte 4:1 IMA-ADPCM payload <= 250B ESP-NOW limit).
/// Zero-copy castable via `bytemuck::from_bytes` in 0 CPU cycles.
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct FlugPacket {
    pub magic: u16,
    pub pkt_type: u8,
    pub lang: u8,
    pub seq_num: u16,
    pub predictor: i16,
    pub index: i8,
    pub payload_len: u8,
    pub payload: [u8; ADPCM_BYTES],
}

const _: () = assert!(core::mem::size_of::<FlugPacket>() == 170);
const _: () = assert!(core::mem::size_of::<FlugPacket>() <= 250);

#[derive(Default, Copy, Clone, Debug, PartialEq, Eq)]
pub struct AdpcmState {
    pub predictor: i32,
    pub index: i32,
}

static IMA_INDEX_LUT: [i32; 16] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
static IMA_STEP_LUT: [i32; 89] = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
    3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
    11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

/// Wild Trick #1: Placed in `.iram1` on Xtensa with branchless arithmetic clamping.
#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
#[inline(always)]
pub fn adpcm_encode_nibble(sample: i16, st: &mut AdpcmState) -> u8 {
    let mut diff = (sample as i32) - st.predictor;
    let sign = ((diff < 0) as u8) << 3;
    diff = diff.abs();

    // SAFETY: st.index is strictly clamped to 0..=88
    let mut step = unsafe { *IMA_STEP_LUT.get_unchecked(st.index as usize) };
    let mut vpdiff = step >> 3;
    let mut nibble = sign;

    let b2 = (diff >= step) as i32;
    nibble |= (b2 as u8) << 2;
    diff -= b2 * step;
    vpdiff += b2 * step;
    step >>= 1;

    let b1 = (diff >= step) as i32;
    nibble |= (b1 as u8) << 1;
    diff -= b1 * step;
    vpdiff += b1 * step;
    step >>= 1;

    let b0 = (diff >= step) as i32;
    nibble |= b0 as u8;
    vpdiff += b0 * step;

    st.predictor += if sign != 0 { -vpdiff } else { vpdiff };
    st.predictor = st.predictor.clamp(-32768, 32767);
    st.index = (st.index + unsafe { *IMA_INDEX_LUT.get_unchecked((nibble & 0x0F) as usize) }).clamp(0, 88);

    nibble & 0x0F
}

#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
pub fn encode_adpcm_frame(pcm: &[i16; ADPCM_SAMPLES], out: &mut [u8; ADPCM_BYTES], st: &mut AdpcmState) {
    for i in 0..ADPCM_BYTES {
        let lo = adpcm_encode_nibble(pcm[i * 2], st);
        let hi = adpcm_encode_nibble(pcm[i * 2 + 1], st);
        out[i] = (hi << 4) | lo;
    }
}

#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
#[inline(always)]
pub fn adpcm_decode_nibble(nibble: u8, st: &mut AdpcmState) -> i16 {
    let step = unsafe { *IMA_STEP_LUT.get_unchecked(st.index as usize) };
    let mut vpdiff = step >> 3;
    if (nibble & 4) != 0 { vpdiff += step; }
    if (nibble & 2) != 0 { vpdiff += step >> 1; }
    if (nibble & 1) != 0 { vpdiff += step >> 2; }

    st.predictor += if (nibble & 8) != 0 { -vpdiff } else { vpdiff };
    st.predictor = st.predictor.clamp(-32768, 32767);
    st.index = (st.index + unsafe { *IMA_INDEX_LUT.get_unchecked((nibble & 0x0F) as usize) }).clamp(0, 88);
    st.predictor as i16
}

#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
pub fn decode_adpcm_frame(adpcm: &[u8; ADPCM_BYTES], pcm: &mut [i16; ADPCM_SAMPLES], st: &mut AdpcmState) {
    for i in 0..ADPCM_BYTES {
        let byte = adpcm[i];
        pcm[i * 2]     = adpcm_decode_nibble(byte & 0x0F, st);
        pcm[i * 2 + 1] = adpcm_decode_nibble(byte >> 4, st);
    }
}
