// Strataris — radio voice callouts.
//
// Synthesised speech for key events ("Shields low", "Mothership detected", …),
// rendered offline to PCM and played back THROUGH the game's synth so it can be
// band-pass filtered + crackled into a radio-comms voice. Bracketed by a
// squelch-static burst in and a "10-4" roger bleep out. Respects the mute.

import AVFoundation

final class VoiceComms {
    private let synth = AVSpeechSynthesizer()
    private weak var audio: AudioEngine?
    private let voice = AVSpeechSynthesisVoice(language: "en-US")

    init(audio: AudioEngine) { self.audio = audio }

    func say(_ text: String) {
        // Skip entirely when muted or the voice channel is turned down to zero
        // — no squelch, no bleep, no speech.
        guard let audio = audio, !audio.muted, audio.voiceGain > 0.001 else { return }
        audio.squelchIn()

        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = 0.50
        u.pitchMultiplier = 0.9
        u.volume = 1

        var samples: [Float] = []
        var rate: Float = 22_050
        synth.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {                       // terminal buffer → play it
                let clip = samples, clipRate = rate
                let dur = Double(clip.count) / Double(clipRate)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    audio.playVoice(samples: clip, rate: clipRate)         // after the squelch lands
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + dur + 0.05) {
                    audio.rogerBleep()
                }
                return
            }
            rate = Float(pcm.format.sampleRate)
            let n = Int(pcm.frameLength)
            if let ch = pcm.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            } else if let ci = pcm.int16ChannelData {
                let p = ci[0]
                for k in 0..<n { samples.append(Float(p[k]) / 32_768) }
            }
        }
    }
}
