#![cfg_attr(not(test), no_std)]

pub mod aye_simd;
pub mod flugos_wire;
pub mod node_mouth_q15;

#[cfg(test)]
mod tests {
    use super::aye_simd::*;
    use super::flugos_wire::*;
    use super::node_mouth_q15::*;

    #[test]
    fn test_zero_copy_bytemuck_and_branchless_adpcm() {
        assert_eq!(core::mem::size_of::<FlugPacket>(), 170);

        let mut src_pcm = [0i16; ADPCM_SAMPLES];
        for (i, s) in src_pcm.iter_mut().enumerate() {
            let env = if i < 32 { i as f64 / 32.0 } else { 1.0 };
            let t = i as f64 / 16000.0;
            *s = (env * 12000.0 * (2.0 * core::f64::consts::PI * 300.0 * t).sin()) as i16;
        }

        let mut enc_st = AdpcmState::default();
        let mut pkt = FlugPacket {
            magic: FLUGOS_MAGIC,
            pkt_type: PktType::AudioAdpcm as u8,
            lang: Lang::Ja as u8,
            seq_num: 7,
            predictor: enc_st.predictor as i16,
            index: enc_st.index as i8,
            payload_len: ADPCM_BYTES as u8,
            payload: [0u8; ADPCM_BYTES],
        };
        encode_adpcm_frame(&src_pcm, &mut pkt.payload, &mut enc_st);

        // Zero-copy cast to raw bytes and back via bytemuck::Pod
        let wire_bytes: &[u8] = bytemuck::bytes_of(&pkt);
        assert_eq!(wire_bytes.len(), 170);
        let rx_pkt: &FlugPacket = bytemuck::from_bytes(wire_bytes);
        assert_eq!(rx_pkt.magic, FLUGOS_MAGIC);
        assert_eq!(rx_pkt.seq_num, 7);

        let mut dec_st = AdpcmState {
            predictor: rx_pkt.predictor as i32,
            index: rx_pkt.index as i32,
        };
        let mut dec_pcm = [0i16; ADPCM_SAMPLES];
        decode_adpcm_frame(&rx_pkt.payload, &mut dec_pcm, &mut dec_st);

        let mut sig_pow = 0.0f64;
        let mut err_pow = 0.0f64;
        for i in 32..ADPCM_SAMPLES {
            let s = src_pcm[i] as f64;
            let e = (src_pcm[i] - dec_pcm[i]) as f64;
            sig_pow += s * s;
            err_pow += e * e;
        }
        let snr_db = 10.0 * (sig_pow / (err_pow + 1e-9)).log10();
        assert!(snr_db > 38.0, "Expected >38 dB SNR, got {:.2} dB", snr_db);
    }

    #[test]
    fn test_simd_pie_energy_zcr_and_int8_dot() {
        let mut pcm = [0i16; 320];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = if i % 4 < 2 { 4000 } else { -4000 };
        }
        let (rms, zcr) = simd_pie_energy_and_zcr(&pcm);
        assert_eq!(rms, 4000);
        assert_eq!(zcr, 159);

        let w = Aligned16([2i8; 32]);
        let a = Aligned16([3i8; 32]);
        let dot = unsafe { pie_int8_dot_16x(w.0.as_ptr(), a.0.as_ptr(), 2) };
        assert_eq!(dot, 32 * 6);
    }

    #[test]
    fn test_q15_trilingual_formant_synthesizer() {
        let mut r1 = Q15Biquad::default();
        let mut r2 = Q15Biquad::default();
        let mut phase: u32 = 0;
        let mut lfsr: u32 = 0xACE1;
        let mut dma_buf = [0i16; 256];

        for fm in TRILINGUAL_Q15_LUT.iter() {
            render_q15_phoneme_chunk(fm, &mut r1, &mut r2, &mut phase, &mut lfsr, &mut dma_buf);
            if fm.ch != b' ' {
                let peak = dma_buf.iter().map(|s| (*s as i32).abs()).max().unwrap_or(0);
                assert!(peak > 50, "Phoneme {:?} produced zero output", fm.ch as char);
            }
        }
    }
}
