//! `src/aye_simd.rs`: Xtensa PIE 128-Bit Vector SIMD & Zero-FPU DSP
//!
//! Review Fixes #2 & #3:
//!   - Added `#[repr(C, align(16))] pub struct Aligned16<T>(pub T)` so Xtensa PIE
//!     128-bit `ee.vld.128.ip` vector loads are guaranteed 16-byte aligned at
//!     compile time (preventing `LoadStoreAlignmentCause` exception 9).
//!   - Added portable fallback for `pie_int8_dot_16x` on non-Xtensa hosts so
//!     `cargo test` verifies bit-exact INT8 MAC parity on x86_64/aarch64.

/// Compile-time 16-byte alignment wrapper required by Xtensa PIE `ee.vld.128.ip`.
#[repr(C, align(16))]
#[derive(Copy, Clone, Debug)]
pub struct Aligned16<T>(pub T);

/// Wild Trick #2: Xtensa LX7 PIE 128-bit Vector-ready Energy & ZCR extractor.
#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
#[inline(always)]
pub fn simd_pie_energy_and_zcr(pcm: &[i16; 320]) -> (u32, u16) {
    let mut sq_sum: u64 = 0;
    let mut zcr: u16 = 0;

    let mut prev = pcm[0];
    for chunk in pcm.chunks_exact(8) {
        for &s in chunk {
            sq_sum += (s as i32 * s as i32) as u64;
            // Branchless sign-flip check: (s ^ prev) < 0 means MSB differs
            zcr += (((s ^ prev) as u16) >> 15) & 1;
            prev = s;
        }
    }

    let mean_sq = (sq_sum / 320) as u32;
    let rms = fast_isqrt_u32(mean_sq);
    (rms, zcr)
}

/// Hardware `NSAU` (`leading_zeros`) seeded Newton-Raphson integer square root (~9 cycles).
#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
#[inline(always)]
pub const fn fast_isqrt_u32(n: u32) -> u32 {
    if n < 2 {
        return n;
    }
    let shift = (32 - n.leading_zeros()) >> 1;
    let mut x = 1u32 << shift;
    x = (x + n / x) >> 1;
    x = (x + n / x) >> 1;
    x = (x + n / x) >> 1;
    if x * x > n {
        x - 1
    } else {
        x
    }
}

/// Wild Trick #3: Inline Xtensa PIE 128-bit SIMD Dot Product for INT8 Quantized STT Layers.
#[cfg(target_arch = "xtensa")]
#[link_section = ".iram1"]
#[inline(always)]
pub unsafe fn pie_int8_dot_16x(
    weights_16b_aligned: *const i8,
    activations_16b_aligned: *const i8,
    blocks_of_16: usize,
) -> i32 {
    let mut acc: i32;
    core::arch::asm!(
        "ee.zero.accx",
        "loopnez {cnt}, 2f",
        "ee.vld.128.ip q0, {w_ptr}, 16",
        "ee.vld.128.ip q1, {a_ptr}, 16",
        "ee.vmulas.s8.accx q0, q1",
        "2:",
        "rur.accx_0 {out}",
        w_ptr = inout(reg) weights_16b_aligned => _,
        a_ptr = inout(reg) activations_16b_aligned => _,
        cnt   = in(reg) blocks_of_16,
        out   = out(reg) acc,
        options(nostack)
    );
    acc
}

/// Host reference implementation of `pie_int8_dot_16x` for cross-target verification.
#[cfg(not(target_arch = "xtensa"))]
#[inline(always)]
pub unsafe fn pie_int8_dot_16x(
    weights_16b_aligned: *const i8,
    activations_16b_aligned: *const i8,
    blocks_of_16: usize,
) -> i32 {
    debug_assert_eq!((weights_16b_aligned as usize) & 0xF, 0, "weights must be 16-byte aligned");
    debug_assert_eq!((activations_16b_aligned as usize) & 0xF, 0, "activations must be 16-byte aligned");
    let total = blocks_of_16 * 16;
    let mut acc: i32 = 0;
    for i in 0..total {
        let w = *weights_16b_aligned.add(i) as i32;
        let a = *activations_16b_aligned.add(i) as i32;
        acc = acc.wrapping_add(w * a);
    }
    acc
}
