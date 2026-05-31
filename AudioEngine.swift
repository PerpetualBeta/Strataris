// Strataris — procedural audio.
//
// No sound assets — everything is synthesised in code, which suits the retro
// aesthetic. An AVAudioSourceNode pulls from a small voice pool; the game
// thread triggers one-shot SFX (each a waveform with a frequency slide and an
// attack/decay envelope), voice 0 is a sustained engine hum, and the title
// screen drives a gentle arpeggio through `note()`. All mixing happens in the
// render callback on the audio thread, guarded by a heap-stable lock.

import AVFoundation
import os

final class AudioEngine {
    // Waveforms.
    static let sine = 0, square = 1, triangle = 2, saw = 3, noise = 4, rumble = 5

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private let sr: Float = 44_100
    var muted = false

    private struct Voice {
        var active = false
        var sustained = false      // engine hum: ignores duration
        var phase: Float = 0
        var freq: Float = 0
        var slide: Float = 1       // per-sample multiplicative pitch slide
        var samplesLeft = 0
        var total = 0
        var attack = 0
        var delay = 0              // silent lead-in (lets us sequence jingles)
        var amp: Float = 0
        var wave = 0
        var rng: UInt32 = 0x1234_5678
        var lp: Float = 0          // low-pass state (for the rocket rumble)
    }
    private var voices = [Voice](repeating: Voice(), count: 24)

    // Voice-clip playback (band-limited, crackly radio voice).
    private var voiceSamples: [Float] = []
    private var voiceRate: Float = 22_050
    private var voicePos: Float = 0
    private var voicePlaying = false
    private var vLP1: Float = 0, vLP2: Float = 0       // band-pass filter state
    private var vRng: UInt32 = 0x00BEEF01

    // Heap-allocated lock for a stable address across lock/unlock calls.
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1)!
        srcNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
            guard let self = self else { return noErr }
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let out = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            self.render(out, frames)
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.55
        try? engine.start()
    }

    deinit { lock.deallocate() }

    // MARK: Render (audio thread)

    private func render(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
        for i in 0..<frames { out[i] = 0 }
        os_unfair_lock_lock(lock)
        for v in 0..<voices.count where voices[v].active {
            var voice = voices[v]
            for i in 0..<frames {
                if voice.delay > 0 { voice.delay -= 1; continue }
                if !voice.sustained && voice.samplesLeft <= 0 { voice.active = false; break }
                let env: Float
                if voice.sustained {
                    env = 1
                } else {
                    let elapsed = voice.total - voice.samplesLeft
                    env = elapsed < voice.attack
                        ? Float(elapsed) / Float(max(1, voice.attack))
                        : Float(voice.samplesLeft) / Float(max(1, voice.total - voice.attack))
                }
                out[i] += osc(&voice) * voice.amp * env
                voice.phase += voice.freq / sr
                if voice.phase >= 1 { voice.phase -= 1 }
                voice.freq *= voice.slide
                if !voice.sustained { voice.samplesLeft -= 1 }
            }
            voices[v] = voice
        }

        // Voice clip: resample-step the speech, band-pass it (~350–2800 Hz)
        // for a radio-comms timbre, and add crackle/dropouts.
        if voicePlaying && voiceSamples.count > 1 {
            let step = voiceRate / sr
            let last = voiceSamples.count - 1
            for i in 0..<frames {
                if voicePos >= Float(last) { voicePlaying = false; break }
                let i0 = Int(voicePos), fr = voicePos - Float(Int(voicePos))
                let s = voiceSamples[i0] * (1 - fr) + voiceSamples[i0 + 1] * fr
                vLP1 += (s - vLP1) * 0.40            // lowpass (cut highs)
                vLP2 += (vLP1 - vLP2) * 0.05         // slow lowpass → subtract = highpass
                var band = (vLP1 - vLP2) * 2.2       // band-pass + makeup gain
                vRng = vRng &* 1_664_525 &+ 1_013_904_223
                let r = Float((vRng >> 9) & 0xFFFF) / 65535
                if r < 0.02 { band *= 0.45 }         // brief dropout
                band += (r - 0.5) * 0.04             // light static speckle
                out[i] += band
                voicePos += step
            }
        }
        os_unfair_lock_unlock(lock)
        if muted {
            for i in 0..<frames { out[i] = 0 }
        } else {
            for i in 0..<frames { out[i] = tanhf(out[i] * 0.9) }   // gentle limiter
        }
    }

    @inline(__always) private func osc(_ v: inout Voice) -> Float {
        switch v.wave {
        case AudioEngine.square:   return v.phase < 0.5 ? 1 : -1
        case AudioEngine.triangle: return 4 * abs(v.phase - 0.5) - 1
        case AudioEngine.saw:      return 2 * v.phase - 1
        case AudioEngine.noise:
            v.rng = v.rng &* 1_664_525 &+ 1_013_904_223
            return Float(v.rng >> 9) / Float(1 << 23) - 1
        case AudioEngine.rumble:
            // Low-pass-filtered white noise → a deep rocket-engine rumble.
            v.rng = v.rng &* 1_664_525 &+ 1_013_904_223
            let white = Float(v.rng >> 9) / Float(1 << 23) - 1
            v.lp += (white - v.lp) * 0.06          // low cutoff
            return v.lp * 3.0                       // compensate for filter attenuation
        default:                   return sinf(2 * .pi * v.phase)   // sine
        }
    }

    // MARK: Triggering (game thread)

    func trigger(wave: Int, f0: Float, f1: Float, dur: Float, amp: Float,
                 attack: Float = 0.003, delay: Float = 0) {
        let total = max(1, Int(dur * sr))
        let slide = (f0 > 0 && f1 > 0) ? powf(f1 / f0, 1 / Float(total)) : 1
        os_unfair_lock_lock(lock)
        var idx = -1, oldest = Int.max
        for v in 1..<voices.count {           // voice 0 reserved for the engine hum
            if !voices[v].active { idx = v; break }
            if voices[v].samplesLeft < oldest { oldest = voices[v].samplesLeft; idx = v }
        }
        if idx >= 0 {
            voices[idx] = Voice(active: true, sustained: false, phase: 0, freq: f0, slide: slide,
                                samplesLeft: total, total: total, attack: Int(attack * sr),
                                delay: Int(delay * sr), amp: amp, wave: wave,
                                rng: UInt32(truncatingIfNeeded: 0x9E37 &+ idx &* 2654435))
        }
        os_unfair_lock_unlock(lock)
    }

    /// Sustained engine hum on voice 0; pitch rises gently with speed.
    func engine(on: Bool, speed: Float) {
        os_unfair_lock_lock(lock)
        if on {
            voices[0].active = true; voices[0].sustained = true; voices[0].wave = AudioEngine.rumble
            voices[0].freq = 1; voices[0].slide = 1
            voices[0].amp = 0.20 + min(0.10, speed * 0.0005)   // a little louder at speed
        } else {
            voices[0].active = false; voices[0].sustained = false
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: SFX presets

    func note(freq: Float, dur: Float, amp: Float, wave: Int) {
        trigger(wave: wave, f0: freq, f1: freq, dur: dur, amp: amp, attack: 0.008)
    }
    func playerShot()   { trigger(wave: AudioEngine.saw,    f0: 880, f1: 170, dur: 0.10, amp: 0.20) }
    func enemyShot()    { trigger(wave: AudioEngine.square, f0: 500, f1: 260, dur: 0.10, amp: 0.13) }
    func bomb()         { trigger(wave: AudioEngine.sine, f0: 720, f1: 130, dur: 0.5, amp: 0.13) }   // falling whistle
    func shieldHit()    { trigger(wave: AudioEngine.square, f0: 230, f1: 130, dur: 0.14, amp: 0.24) }
    func kill() {
        trigger(wave: AudioEngine.noise,  f0: 1, f1: 1,  dur: 0.30, amp: 0.28)
        trigger(wave: AudioEngine.square, f0: 180, f1: 60, dur: 0.28, amp: 0.18)
    }
    func structureLost() {                                  // big, deep building explosion
        trigger(wave: AudioEngine.noise,  f0: 1, f1: 1,   dur: 0.70, amp: 0.42)
        trigger(wave: AudioEngine.square, f0: 110, f1: 28, dur: 0.65, amp: 0.30)
        trigger(wave: AudioEngine.sine,   f0: 70, f1: 20,  dur: 0.72, amp: 0.22, delay: 0.04)
    }
    func warp() { trigger(wave: AudioEngine.sine, f0: 200, f1: 1300, dur: 0.5, amp: 0.22) }
    func whoosh(rising: Bool) {                              // launch / re-entry sweep
        trigger(wave: AudioEngine.noise, f0: 1, f1: 1, dur: 0.8, amp: 0.16)
        trigger(wave: AudioEngine.sine, f0: rising ? 180 : 1300, f1: rising ? 1300 : 180, dur: 0.8, amp: 0.14)
    }
    func uiStart() { trigger(wave: AudioEngine.square, f0: 600, f1: 950, dur: 0.12, amp: 0.22) }
    func planetCleared() {
        let notes: [Float] = [392, 523, 659, 784]   // G C E G
        for (i, f) in notes.enumerated() {
            trigger(wave: AudioEngine.triangle, f0: f, f1: f, dur: 0.18, amp: 0.18, attack: 0.006,
                    delay: Float(i) * 0.10)
        }
    }
    func gameOver() {
        let notes: [Float] = [330, 247, 165]
        for (i, f) in notes.enumerated() {
            trigger(wave: AudioEngine.triangle, f0: f, f1: f * 0.98, dur: 0.32, amp: 0.20, attack: 0.006,
                    delay: Float(i) * 0.18)
        }
    }

    /// Hand a rendered speech clip to the synth's render path (filtered playback).
    func playVoice(samples: [Float], rate: Float) {
        os_unfair_lock_lock(lock)
        voiceSamples = samples; voiceRate = rate; voicePos = 0; voicePlaying = true
        vLP1 = 0; vLP2 = 0
        os_unfair_lock_unlock(lock)
    }

    // Radio comms FX (bracket voice callouts).
    func squelchIn() {
        trigger(wave: AudioEngine.noise, f0: 1, f1: 1, dur: 0.16, amp: 0.16)
        trigger(wave: AudioEngine.square, f0: 1700, f1: 520, dur: 0.13, amp: 0.06)
    }
    func rogerBleep() {                                     // rapid double-beep
        trigger(wave: AudioEngine.square, f0: 1500, f1: 1500, dur: 0.06, amp: 0.13, attack: 0.003)
        trigger(wave: AudioEngine.square, f0: 1500, f1: 1500, dur: 0.06, amp: 0.13, attack: 0.003, delay: 0.09)
    }
}
