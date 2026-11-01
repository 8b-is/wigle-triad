//! `#![no_std]` ESP-Mosaico Multi-Function Interaction Module (`board_id = 0x16`)
//! driver for `aye-flug-os` (Left Slot `H2` @ `0x50` / Right Slot `H1` @ `0x51`).

pub const MOSAICO_BOARD_ID_INTERACTION: u8 = 0x16;
pub const MOSAICO_EEPROM_ADDR_LEFT_H2: u8 = 0x50;
pub const MOSAICO_EEPROM_ADDR_RIGHT_H1: u8 = 0x51;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MosaicoSlot {
    LeftH2 = 0,
    RightH1 = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MosaicoPins {
    pub slot: MosaicoSlot,
    pub eeprom_i2c_addr: u8,
    pub addr_sel_gpio: u8,
    pub addr_sel_level: u8,
    pub ldr_adc_gpio: u8,
    pub pir_gpio: u8,
    pub ir_tx_gpio: u8,
    pub ws2812_gpio: u8,
    pub key_left_gpio: u8,
    pub key_right_gpio: u8,
}

#[inline]
pub const fn probe_mosaico_slot(slot: MosaicoSlot, eeprom_board_id: u8) -> Option<MosaicoPins> {
    if eeprom_board_id != MOSAICO_BOARD_ID_INTERACTION {
        return None;
    }
    match slot {
        MosaicoSlot::LeftH2 => Some(MosaicoPins {
            slot: MosaicoSlot::LeftH2,
            eeprom_i2c_addr: MOSAICO_EEPROM_ADDR_LEFT_H2,
            addr_sel_gpio: 14,
            addr_sel_level: 0,
            ldr_adc_gpio: 53,
            pir_gpio: 4,
            ir_tx_gpio: 48,
            ws2812_gpio: 15,
            key_left_gpio: 13,
            key_right_gpio: 12,
        }),
        MosaicoSlot::RightH1 => Some(MosaicoPins {
            slot: MosaicoSlot::RightH1,
            eeprom_i2c_addr: MOSAICO_EEPROM_ADDR_RIGHT_H1,
            addr_sel_gpio: 39,
            addr_sel_level: 1,
            ldr_adc_gpio: 46,
            pir_gpio: 5,
            ir_tx_gpio: 47,
            ws2812_gpio: 38,
            key_left_gpio: 11,
            key_right_gpio: 10,
        }),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QuiescenceGateQ15 {
    pub flux_ema_q15: u16,
    pub quiet_thresh_q15: u16,
    pub wake_thresh_q15: u16,
    pub hold_ticks_required: u16,
    pub quiet_ticks_accum: u16,
    pub in_ultradreamstate: bool,
}

impl QuiescenceGateQ15 {
    #[inline]
    pub const fn new(quiet_thresh_q15: u16, wake_thresh_q15: u16, hold_ticks_required: u16) -> Self {
        let wake = if wake_thresh_q15 > quiet_thresh_q15 {
            wake_thresh_q15
        } else {
            quiet_thresh_q15.saturating_add(1024)
        };
        let hold = if hold_ticks_required > 0 {
            hold_ticks_required
        } else {
            1
        };
        Self {
            flux_ema_q15: wake,
            quiet_thresh_q15,
            wake_thresh_q15: wake,
            hold_ticks_required: hold,
            quiet_ticks_accum: 0,
            in_ultradreamstate: false,
        }
    }

    #[inline]
    pub fn step(
        &mut self,
        ldr_permille: u16,
        pir_motion: bool,
        key_left: bool,
        key_right: bool,
        audio_rms_q15: u16,
    ) -> bool {
        let clamped_ldr = if ldr_permille > 1000 { 1000 } else { ldr_permille as u32 };
        let light_q15 = (clamped_ldr * 32767) / 1000;
        let motion_q15 = if pir_motion || key_left || key_right { 32767 } else { 0 };
        let mut inst_flux = ((audio_rms_q15 as u32) * 2 + motion_q15 + light_q15) >> 2;
        if inst_flux > 32767 {
            inst_flux = 32767;
        }
        self.flux_ema_q15 = (((self.flux_ema_q15 as u32) * 3 + inst_flux) >> 2) as u16;

        if !self.in_ultradreamstate {
            if self.flux_ema_q15 < self.quiet_thresh_q15 {
                self.quiet_ticks_accum = self.quiet_ticks_accum.saturating_add(1);
                if self.quiet_ticks_accum >= self.hold_ticks_required {
                    self.in_ultradreamstate = true;
                }
            } else {
                self.quiet_ticks_accum = 0;
            }
        } else if self.flux_ema_q15 > self.wake_thresh_q15 || pir_motion || key_left || key_right {
            self.in_ultradreamstate = false;
            self.quiet_ticks_accum = 0;
        }
        self.in_ultradreamstate
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Ws2812Grb {
    pub g: u8,
    pub r: u8,
    pub b: u8,
}

#[inline]
pub const fn encode_ws2812_trits(trits: &[i8; 6]) -> [Ws2812Grb; 6] {
    let mut out = [Ws2812Grb { g: 0, r: 0, b: 0 }; 6];
    let mut i = 0;
    while i < 6 {
        out[i] = if trits[i] > 0 {
            Ws2812Grb { g: 0xF5, r: 0x00, b: 0xD4 }
        } else if trits[i] < 0 {
            Ws2812Grb { g: 0x2A, r: 0xFF, b: 0x85 }
        } else {
            Ws2812Grb { g: 0x18, r: 0x12, b: 0x24 }
        };
        i += 1;
    }
    out
}

#[inline]
pub const fn encode_nec_ir(addr: u8, cmd: u8) -> u32 {
    let n_addr = !addr;
    let n_cmd = !cmd;
    (addr as u32) | ((n_addr as u32) << 8) | ((cmd as u32) << 16) | ((n_cmd as u32) << 24)
}
