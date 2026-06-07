// Strataris — procedural audio.
//
// No sound assets — everything is synthesised in code, which suits the retro
// aesthetic. An AVAudioSourceNode pulls from a small voice pool; the game
// thread triggers one-shot SFX (each a waveform with a frequency slide and an
// attack/decay envelope), and voice 0 is a sustained engine hum. All mixing
// happens in the render callback on the audio thread, guarded by a heap-stable
// lock.

import AVFoundation
import os

final class AudioEngine {
    // Waveforms. `string` is a Karplus-Strong plucked string (physical model),
    // handled specially in the render loop rather than as a phase oscillator.
    static let sine = 0, square = 1, triangle = 2, saw = 3, noise = 4, rumble = 5, string = 6

    // Voice 0 = engine hum; voices 1–2 = the sustained per-planet ambient bed;
    // one-shot SFX draw from voice `sfxVoice0` upward.
    static let ambientVoice0 = 1, ambientVoiceCount = 2, sfxVoice0 = 3

    // Mixer buses — each scaled by its own category gain in the render callback.
    static let busSFX = 0, busMusic = 1, busAmbient = 2

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private let sr: Float = 44_100
    var muted = false

    // Per-category gains (0...1), set from the options screen and persisted via
    // GameSettings. Read on the audio thread without a lock — Float load/store
    // is effectively atomic here and a stale sample is inaudible.
    var musicGain: Float = 1
    var sfxGain: Float = 1
    var voiceGain: Float = 1
    var ambientGain: Float = 1

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
        var bus = 0                // mixer bus: busSFX / busMusic / busAmbient
        var rng: UInt32 = 0x1234_5678
        var lp: Float = 0          // low-pass state (for the rocket rumble)
        var cutoff: Float = 0.06   // rumble low-pass coefficient (higher = brighter/windier)
        var drive: Float = 1       // >1 → tanh waveshaping (overdrive/distortion)
        var pluck = false          // true → exponential ring-down (plucked string)
    }
    private var voices = [Voice](repeating: Voice(), count: 24)

    // Karplus-Strong plucked-string state, one delay line per voice slot (used
    // only by `wave == string`). Kept in parallel arrays — NOT in the Voice
    // struct — so the render loop's per-voice struct copy stays cheap.
    private let ksMaxLen = 1200                 // covers strings down to ~37 Hz at 44.1 k
    private var ksBuf: [[Float]]
    private var ksPos = [Int](repeating: 0, count: 24)
    private var ksLen = [Int](repeating: 1, count: 24)
    private var ksDecay = [Float](repeating: 1, count: 24)
    private var ksEnv = [Float](repeating: 0, count: 24)   // peak follower → sustain compression
    private var ksSeed: UInt32 = 0x1234_5678    // varies the pick-noise per pluck

    // Per-planet ambience: a sustained bed (voices 1–2) plus sparse one-shot
    // events scheduled on the game thread. `ambientName` tracks which profile's
    // bed is currently configured, so we only rebuild the bed voices (a click)
    // when the planet actually changes — not every frame.
    private var ambientProfile: AmbientProfile?
    private var ambientName = ""
    private var ambientEventCountdown: Float = 0
    private var ambientFade: Float = 0                    // 0…1 master fade for the ambient bus
    private static let ambientFadeRate: Float = 1.0 / 1.2 // full cross-fade ≈ 1.2 s

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
        ksBuf = Array(repeating: [Float](repeating: 0, count: ksMaxLen), count: voices.count)
        let s = GameSettings.shared
        musicGain = s.musicVolume
        sfxGain = s.sfxVolume
        voiceGain = s.voiceVolume
        ambientGain = s.ambientVolume

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
                    if elapsed < voice.attack {
                        env = Float(elapsed) / Float(max(1, voice.attack))
                    } else if voice.wave == AudioEngine.string {
                        // Sustain-compressed string: its own level is flattened,
                        // so the amp env shapes the decay — an exponential fade
                        // (electric-guitar sustain that sings then dies away),
                        // with a short release guard against an end click.
                        let e = Float(elapsed - voice.attack) / Float(max(1, voice.total - voice.attack))
                        env = expf(-3.0 * e) * (voice.samplesLeft < 600 ? Float(voice.samplesLeft) / 600 : 1)
                    } else if voice.pluck {
                        // Exponential ring-down: a string trails off rather than
                        // fading linearly to a sudden stop.
                        let e = Float(elapsed - voice.attack) / Float(max(1, voice.total - voice.attack))
                        env = expf(-4.0 * e)
                    } else {
                        env = Float(voice.samplesLeft) / Float(max(1, voice.total - voice.attack))
                    }
                }
                let busGain = voice.bus == AudioEngine.busMusic ? musicGain
                            : voice.bus == AudioEngine.busAmbient ? ambientGain * ambientFade : sfxGain
                var sample: Float
                if voice.wave == AudioEngine.string {
                    // Karplus-Strong: read the delay line, write back the
                    // low-pass-averaged (+ slight decay) value — the loop
                    // resonates and damps like a real plucked string.
                    let n = ksLen[v], p = ksPos[v]
                    let nxt = p + 1 == n ? 0 : p + 1
                    let raw = ksBuf[v][p]
                    ksBuf[v][p] = ksDecay[v] * 0.5 * (raw + ksBuf[v][nxt])
                    ksPos[v] = nxt
                    // Sustain compression: a peak follower (fast attack, slow
                    // release) tracks the string's level; dividing by it holds
                    // the signal near unity as the string decays, so the drive
                    // below stays saturated (singing electric sustain) instead of
                    // cleaning up into a koto-like ring. The amp envelope, not the
                    // string level, then shapes the note's decay.
                    let a = abs(raw)
                    ksEnv[v] += (a - ksEnv[v]) * (a > ksEnv[v] ? 0.5 : 0.0006)
                    sample = raw / max(ksEnv[v], 0.04)
                } else {
                    sample = osc(&voice)
                }
                if voice.drive > 1 { sample = tanhf(sample * voice.drive) }   // overdrive
                out[i] += sample * voice.amp * env * busGain
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
                out[i] += band * voiceGain
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
            // Low-pass-filtered white noise → a deep rocket rumble at a low
            // cutoff, an airy wind hiss at a higher one (per-voice `cutoff`).
            v.rng = v.rng &* 1_664_525 &+ 1_013_904_223
            let white = Float(v.rng >> 9) / Float(1 << 23) - 1
            v.lp += (white - v.lp) * v.cutoff
            return v.lp * (0.73 / sqrtf(v.cutoff))  // makeup gain ≈ constant across cutoffs
        default:                   return sinf(2 * .pi * v.phase)   // sine
        }
    }

    // MARK: Triggering (game thread)

    func trigger(wave: Int, f0: Float, f1: Float, dur: Float, amp: Float,
                 attack: Float = 0.003, delay: Float = 0, music: Bool = false,
                 ambient: Bool = false, cutoff: Float = 0.06, drive: Float = 1,
                 pluck: Bool = false) {
        let total = max(1, Int(dur * sr))
        let slide = (f0 > 0 && f1 > 0) ? powf(f1 / f0, 1 / Float(total)) : 1
        let bus = music ? AudioEngine.busMusic : (ambient ? AudioEngine.busAmbient : AudioEngine.busSFX)
        os_unfair_lock_lock(lock)
        var idx = -1, oldest = Int.max
        for v in AudioEngine.sfxVoice0..<voices.count {   // voices 0–2 reserved (engine hum + ambient bed)
            if !voices[v].active { idx = v; break }
            if voices[v].samplesLeft < oldest { oldest = voices[v].samplesLeft; idx = v }
        }
        if idx >= 0 {
            voices[idx] = Voice(active: true, sustained: false, phase: 0, freq: f0, slide: slide,
                                samplesLeft: total, total: total, attack: Int(attack * sr),
                                delay: Int(delay * sr), amp: amp, wave: wave, bus: bus,
                                rng: UInt32(truncatingIfNeeded: 0x9E37 &+ idx &* 2654435),
                                cutoff: cutoff, drive: drive, pluck: pluck)
        }
        os_unfair_lock_unlock(lock)
    }

    /// Pluck a Karplus-Strong string voice — a physical model of a plucked
    /// string. A tuned delay line (length = sr / freq) is excited with a noise
    /// burst (the "pick"); each sample it's read out and written back through a
    /// two-point averaging low-pass (× a slight `decay`), so the loop resonates
    /// with a full, evolving harmonic body and damps naturally like a real
    /// string — then `drive` overdrives it for an electric tone. `dur` only
    /// bounds how long the voice is held; the timbre's decay is the model's own.
    func pluckString(freq: Float, dur: Float, amp: Float, decay: Float = 0.999, drive: Float = 4) {
        let total = max(1, Int(dur * sr))
        let n = max(2, min(ksMaxLen, Int((sr / freq).rounded())))
        os_unfair_lock_lock(lock)
        var idx = -1, oldest = Int.max
        for v in AudioEngine.sfxVoice0..<voices.count {
            if !voices[v].active { idx = v; break }
            if voices[v].samplesLeft < oldest { oldest = voices[v].samplesLeft; idx = v }
        }
        if idx >= 0 {
            var voice = Voice()
            voice.active = true
            voice.freq = freq
            voice.samplesLeft = total
            voice.total = total
            voice.attack = Int(0.001 * sr)
            voice.amp = amp
            voice.wave = AudioEngine.string
            voice.bus = AudioEngine.busMusic
            voice.drive = drive
            voices[idx] = voice
            // Excite the delay line with a fresh noise burst (the pick).
            ksLen[idx] = n; ksPos[idx] = 0; ksDecay[idx] = decay; ksEnv[idx] = 0
            ksSeed = ksSeed &* 1_664_525 &+ 1_013_904_223
            var r = ksSeed ^ (UInt32(truncatingIfNeeded: idx) &* 2_654_435_761)
            for k in 0..<n {
                r = r &* 1_664_525 &+ 1_013_904_223
                ksBuf[idx][k] = Float(r >> 9) / Float(1 << 23) * 2 - 1
            }
            // Low-pass the excitation (two passes) → a warmer, rounder pluck with
            // less metallic/bell-like high content.
            for _ in 0..<2 {
                var prev = ksBuf[idx][n - 1]
                for k in 0..<n {
                    let cur = ksBuf[idx][k]
                    ksBuf[idx][k] = 0.5 * (cur + prev)
                    prev = cur
                }
            }
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

    // MARK: Per-planet ambience

    /// Select the ambient profile for the current world (call on planet load,
    /// and at warp-descent entry so the new world fades in). Seeds the first
    /// event countdown; the bed's loudness is governed by the master fade.
    func setAmbientProfile(_ p: AmbientProfile) {
        ambientProfile = p
        ambientEventCountdown = Float.random(in: p.eventRange)
    }

    /// Per-frame ambient driver (game thread; call for EVERY state). `active` is
    /// the target presence: the bus ramps toward full while active (on a planet,
    /// or descending on arrival) and toward silence otherwise (warp-out, title,
    /// pause) — so leaving and arriving cross-fade rather than snap. The fade is
    /// applied to the ambient bus in `render`; sparse events fire only once the
    /// bed is audibly present. The bed voices are reconfigured (a click) only on
    /// a genuine planet change, and released when fully faded out.
    func updateAmbient(active: Bool, dt: Float) {
        let target: Float = active ? 1 : 0
        if ambientFade < target {
            ambientFade = min(target, ambientFade + dt * AudioEngine.ambientFadeRate)
        } else if ambientFade > target {
            ambientFade = max(target, ambientFade - dt * AudioEngine.ambientFadeRate)
        }

        guard let p = ambientProfile else { return }

        os_unfair_lock_lock(lock)
        if ambientFade > 0 {
            let rebuild = ambientName != p.name
            ambientName = p.name
            for slot in 0..<AudioEngine.ambientVoiceCount {
                let i = AudioEngine.ambientVoice0 + slot
                if slot < p.beds.count {
                    let b = p.beds[slot]
                    if rebuild {
                        voices[i].wave = b.wave; voices[i].freq = b.freq; voices[i].slide = 1
                        voices[i].amp = b.amp; voices[i].cutoff = b.cutoff; voices[i].phase = 0
                        voices[i].sustained = true; voices[i].bus = AudioEngine.busAmbient
                    }
                    voices[i].active = true; voices[i].sustained = true
                } else {
                    voices[i].active = false
                }
            }
        } else {
            for i in 0..<AudioEngine.ambientVoiceCount { voices[AudioEngine.ambientVoice0 + i].active = false }
        }
        os_unfair_lock_unlock(lock)

        // Sparse events only once the bed is meaningfully present.
        if active && ambientFade > 0.5 {
            ambientEventCountdown -= dt
            if ambientEventCountdown <= 0 {
                p.fire(self)
                ambientEventCountdown = Float.random(in: p.eventRange)
            }
        }
    }

    // MARK: SFX presets

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
    func pulse() {                                          // radial pulse: rising sweep + boom
        trigger(wave: AudioEngine.sine,   f0: 120, f1: 1600, dur: 0.35, amp: 0.22)
        trigger(wave: AudioEngine.noise,  f0: 1, f1: 1,      dur: 0.55, amp: 0.34, delay: 0.12)
        trigger(wave: AudioEngine.square, f0: 90, f1: 24,    dur: 0.55, amp: 0.26, delay: 0.12)
    }
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

// MARK: - Per-planet ambience

/// The atmospheric "voice" of a world: one or two sustained bed layers (a wind
/// hiss and/or a tonal drone) plus a closure that fires sparse one-shot events
/// (gusts, gurgles, crackles, shimmers). All synthesised — no asset files —
/// keyed off `PlanetTheme` so each colony in the cluster *sounds* like itself,
/// not just looks like itself. Amplitudes sit deliberately under the engine
/// hum (~0.20) so the bed is felt more than heard; the events give it life.
struct AmbientProfile {
    struct Bed { let wave: Int; let freq: Float; let amp: Float; let cutoff: Float }

    let name: String                      // matches PlanetTheme.name (bed-rebuild key)
    let beds: [Bed]                       // 1–2 sustained layers (voices 1–2)
    let eventRange: ClosedRange<Float>    // seconds between one-shot events
    let fire: (AudioEngine) -> Void       // trigger the next atmospheric event

    /// A filtered-noise bed layer (wind/rumble): low cutoff = deep, high = airy.
    static func wind(_ amp: Float, cutoff: Float) -> Bed {
        Bed(wave: AudioEngine.rumble, freq: 1, amp: amp, cutoff: cutoff)
    }
    /// A tonal bed layer (a low drone or a soft pad note).
    static func drone(_ wave: Int, _ freq: Float, _ amp: Float) -> Bed {
        Bed(wave: wave, freq: freq, amp: amp, cutoff: 0.06)
    }

    /// The ambience for the world at this theme. Falls back to a neutral breeze.
    static func forTheme(_ theme: PlanetTheme) -> AmbientProfile {
        switch theme.name {

        // Demeter — temperate earthlike: a gentle, airy breeze with soft gusts.
        case "Demeter":
            return AmbientProfile(name: theme.name,
                beds: [wind(0.09, cutoff: 0.18)],
                eventRange: 4...9) { a in
                    a.trigger(wave: AudioEngine.rumble, f0: 1, f1: 1,
                              dur: Float.random(in: 1.2...2.0), amp: Float.random(in: 0.09...0.15),
                              attack: 0.7, ambient: true, cutoff: Float.random(in: 0.14...0.22))
                }

        // Tantalus — rust desert: a drier, lower wind over a hollow moan.
        case "Tantalus":
            return AmbientProfile(name: theme.name,
                beds: [wind(0.08, cutoff: 0.12), drone(AudioEngine.sine, 42, 0.05)],
                eventRange: 5...11) { a in
                    if Bool.random() {                       // a dust-laden gust
                        a.trigger(wave: AudioEngine.rumble, f0: 1, f1: 1,
                                  dur: Float.random(in: 1.4...2.2), amp: Float.random(in: 0.09...0.14),
                                  attack: 0.8, ambient: true, cutoff: Float.random(in: 0.09...0.13))
                    } else {                                 // a distant hollow moan
                        let f = Float.random(in: 80...100)
                        a.trigger(wave: AudioEngine.sine, f0: f, f1: f * 0.8,
                                  dur: 1.9, amp: 0.09, attack: 0.6, ambient: true)
                    }
                }

        // Boreas — ice world: a thin, high, cold wind that whistles; ice creaks.
        case "Boreas":
            return AmbientProfile(name: theme.name,
                beds: [wind(0.09, cutoff: 0.30), drone(AudioEngine.sine, 520, 0.02)],
                eventRange: 4...8) { a in
                    if Bool.random() {                       // wind whistle (rise + fall)
                        let f = Float.random(in: 850...1100)
                        a.trigger(wave: AudioEngine.sine, f0: f, f1: f * 1.6,
                                  dur: 1.1, amp: 0.08, attack: 0.45, ambient: true)
                    } else {                                 // an ice creak
                        let f = Float.random(in: 180...260)
                        a.trigger(wave: AudioEngine.square, f0: f, f1: f * 0.8,
                                  dur: 0.28, amp: 0.09, attack: 0.04, ambient: true)
                    }
                }

        // Pandora — toxic: a murky deep bed with a queasy drone; bubbling gurgles.
        case "Pandora":
            return AmbientProfile(name: theme.name,
                beds: [wind(0.10, cutoff: 0.08), drone(AudioEngine.triangle, 59, 0.05)],
                eventRange: 3...7) { a in
                    if Int.random(in: 0...2) > 0 {           // a bubbling gurgle
                        let n = Int.random(in: 2...4)
                        for i in 0..<n {
                            let f = Float.random(in: 180...320)
                            a.trigger(wave: AudioEngine.sine, f0: f, f1: f * 0.5,
                                      dur: 0.13, amp: Float.random(in: 0.07...0.12),
                                      attack: 0.02, delay: Float(i) * Float.random(in: 0.07...0.13),
                                      ambient: true)
                        }
                    } else {                                 // a venting toxic hiss
                        a.trigger(wave: AudioEngine.rumble, f0: 1, f1: 1,
                                  dur: 0.9, amp: 0.09, attack: 0.35, ambient: true, cutoff: 0.26)
                    }
                }

        // Vulcan — volcanic: a deep ground rumble + sub drone; lava crackle & booms.
        case "Vulcan":
            return AmbientProfile(name: theme.name,
                beds: [wind(0.15, cutoff: 0.05), drone(AudioEngine.sine, 36, 0.05)],
                eventRange: 2.5...6) { a in
                    if Bool.random() {                       // a burst of lava crackle
                        let n = Int.random(in: 3...6)
                        for i in 0..<n {
                            a.trigger(wave: AudioEngine.noise, f0: 1, f1: 1,
                                      dur: Float.random(in: 0.04...0.09), amp: Float.random(in: 0.07...0.15),
                                      delay: Float(i) * Float.random(in: 0.03...0.10), ambient: true)
                        }
                    } else {                                 // a distant deep boom
                        a.trigger(wave: AudioEngine.sine, f0: 72, f1: 24, dur: 0.9, amp: 0.16, attack: 0.02, ambient: true)
                        a.trigger(wave: AudioEngine.noise, f0: 1, f1: 1, dur: 0.5, amp: 0.10, attack: 0.02, ambient: true)
                    }
                }

        // Vesper — violet twilight: a soft open-fifth pad, airy; eerie shimmers.
        case "Vesper":
            return AmbientProfile(name: theme.name,
                beds: [drone(AudioEngine.triangle, 131, 0.05), drone(AudioEngine.triangle, 196, 0.038)],
                eventRange: 5...10) { a in
                    if Bool.random() {                       // a high eerie shimmer
                        let f = Float.random(in: 980...1160)
                        a.trigger(wave: AudioEngine.triangle, f0: f, f1: f * 1.05,
                                  dur: 1.6, amp: 0.045, attack: 0.8, ambient: true)
                    } else {                                 // a soft distant chime
                        let f = Float.random(in: 700...920)
                        a.trigger(wave: AudioEngine.sine, f0: f, f1: f, dur: 0.6, amp: 0.05, attack: 0.05, ambient: true)
                    }
                }

        // Any future world: a neutral breeze.
        default:
            return AmbientProfile(name: theme.name,
                beds: [wind(0.09, cutoff: 0.16)],
                eventRange: 5...10) { a in
                    a.trigger(wave: AudioEngine.rumble, f0: 1, f1: 1,
                              dur: 1.5, amp: 0.10, attack: 0.7, ambient: true, cutoff: 0.16)
                }
        }
    }
}
