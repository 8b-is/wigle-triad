//! `src/node_mouth_q15.rs`: Fixed-Point Q15 Trilingual Formant Engine (JA / EN / HU)
//!
//! Review Fix #4:
//!   - In `Q15Biquad::step`, promoted the MAC accumulation `(b0_q14 * x + a1_q14 * y1 + a2_q14 * y2)`
//!     to `i64` before `>> 14` so resonant high-Q vowel peaks (`a1_q14 = 31910`, `y1 = 32767`)
//!     can never wrap `i32::MAX` (`1.045e9 + 1.045e9`).

#[derive(Copy, Clone, Debug)]
pub struct Q15Formant {
    pub ch: u8,
    pub a1_f1: i32, // Q14 fixed-point feedback coeff 1 (1.0 == 16384)
    pub a2_f1: i32, // Q14 fixed-point feedback coeff 2
    pub a1_f2: i32,
    pub a2_f2: i32,
    pub voiced_q15: i32,
    pub noise_q15: i32,
    pub dur_samples: u16, // @ 16kHz (e.g., 1600 = 100ms mora)
}

/// Precomputed Q14 biquad poles for 16kHz sample rate across JA / HU / EN phonemes
pub static TRILINGUAL_Q15_LUT: [Q15Formant; 12] = [
    // 'A' (JA あ / HU á / EN ah): F1=750Hz, F2=1180Hz
    Q15Formant { ch: b'A', a1_f1: 30612, a2_f1: -15805, a1_f2: 28410, a2_f2: -15650, voiced_q15: 28000, noise_q15: 400,   dur_samples: 1760 },
    // 'I' (JA い / HU í / EN ee): F1=280Hz, F2=2250Hz
    Q15Formant { ch: b'I', a1_f1: 31890, a2_f1: -15920, a1_f2: 20150, a2_f2: -15500, voiced_q15: 28000, noise_q15: 400,   dur_samples: 1600 },
    // 'U' (JA う / HU ü / EN oo): F1=320Hz, F2=1100Hz
    Q15Formant { ch: b'U', a1_f1: 31780, a2_f1: -15900, a1_f2: 28900, a2_f2: -15680, voiced_q15: 28000, noise_q15: 400,   dur_samples: 1680 },
    // 'E' (JA え / HU é / EN eh): F1=500Hz, F2=1900Hz
    Q15Formant { ch: b'E', a1_f1: 31320, a2_f1: -15850, a1_f2: 23400, a2_f2: -15580, voiced_q15: 28000, noise_q15: 400,   dur_samples: 1680 },
    // 'O' (JA お / HU ó / EN oh): F1=480Hz, F2=880Hz
    Q15Formant { ch: b'O', a1_f1: 31380, a2_f1: -15860, a1_f2: 30050, a2_f2: -15720, voiced_q15: 28000, noise_q15: 400,   dur_samples: 1760 },
    // 'K' (JA か / HU k): Unvoiced velar burst
    Q15Formant { ch: b'K', a1_f1: 31700, a2_f1: -15100, a1_f2: 27200, a2_f2: -14900, voiced_q15: 2000,  noise_q15: 18000, dur_samples: 880  },
    // 'S' (JA さ / HU sz): High-frequency sibilant noise
    Q15Formant { ch: b'S', a1_f1: 31500, a2_f1: -14800, a1_f2: 23800, a2_f2: -14600, voiced_q15: 0,     noise_q15: 22000, dur_samples: 1120 },
    // 'N' (JA ん・な / HU n/ny): Nasal murmur
    Q15Formant { ch: b'N', a1_f1: 31910, a2_f1: -15940, a1_f2: 26400, a2_f2: -15400, voiced_q15: 24000, noise_q15: 200,   dur_samples: 1360 },
    // 'R' (JA ら tap / HU trilled r)
    Q15Formant { ch: b'R', a1_f1: 31520, a2_f1: -15820, a1_f2: 26900, a2_f2: -15600, voiced_q15: 25000, noise_q15: 800,   dur_samples: 960  },
    // 'Y' (JA や / HU j/gy)
    Q15Formant { ch: b'Y', a1_f1: 31850, a2_f1: -15910, a1_f2: 21100, a2_f2: -15550, voiced_q15: 26000, noise_q15: 600,   dur_samples: 1200 },
    // 'H' (JA は / HU h)
    Q15Formant { ch: b'H', a1_f1: 31250, a2_f1: -15200, a1_f2: 25800, a2_f2: -15000, voiced_q15: 3000,  noise_q15: 15000, dur_samples: 960  },
    // ' ' (Moraic pause)
    Q15Formant { ch: b' ', a1_f1: 0,     a2_f1: 0,      a1_f2: 0,     a2_f2: 0,      voiced_q15: 0,     noise_q15: 0,     dur_samples: 1280 },
];

#[derive(Default, Copy, Clone, Debug)]
pub struct Q15Biquad {
    pub y1: i32,
    pub y2: i32,
}

impl Q15Biquad {
    #[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
    #[inline(always)]
    pub fn step(&mut self, x: i32, a1_q14: i32, a2_q14: i32) -> i32 {
        let b0_q14 = (16384 - a1_q14 - a2_q14) as i64;
        let acc = b0_q14 * (x as i64)
            + (a1_q14 as i64) * (self.y1 as i64)
            + (a2_q14 as i64) * (self.y2 as i64);
        let y = (acc >> 14) as i32;
        self.y2 = self.y1;
        self.y1 = y.clamp(-32768, 32767);
        self.y1
    }
}

/// Synthesizes a character into a 256-sample DMA slice using pure Q15 integer math.
#[cfg_attr(target_arch = "xtensa", link_section = ".iram1")]
pub fn render_q15_phoneme_chunk(
    fm: &Q15Formant,
    r1: &mut Q15Biquad,
    r2: &mut Q15Biquad,
    phase_q16: &mut u32,
    lfsr: &mut u32,
    out_dma: &mut [i16; 256],
) {
    let f0_inc_q16: u32 = (118 * 65536) / 16000; // 118Hz cybernetic pitch
    for sample_out in out_dma.iter_mut() {
        *phase_q16 = (*phase_q16 + f0_inc_q16) & 0xFFFF;
        // Integer Rosenberg glottal pulse approximation
        let glottal: i32 = if *phase_q16 < 45875 {
            ((*phase_q16 as i32) - 22937) >> 1
        } else {
            -4096
        };

        // Galois LFSR for fricative sibilant noise
        let bit = *lfsr & 1;
        *lfsr = (*lfsr >> 1) ^ (bit.wrapping_neg() & 0xB400);
        let noise = ((*lfsr as i16) as i32) >> 2;

        let exc = (((glottal as i64) * (fm.voiced_q15 as i64) + (noise as i64) * (fm.noise_q15 as i64)) >> 15) as i32;
        let f1_out = r1.step(exc, fm.a1_f1, fm.a2_f1);
        let f2_out = r2.step(exc, fm.a1_f2, fm.a2_f2);

        let mixed = (f1_out + (((f2_out as i64) * 19660) >> 15) as i32).clamp(-32768, 32767);
        *sample_out = mixed as i16;
    }
}
