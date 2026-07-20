import AVFoundation
import Foundation

enum SoundEvent { case blocked, done }

@MainActor
final class SoundEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private unowned let settings: Settings

    init(settings: Settings) { self.settings = settings }

    func play(_ event: SoundEvent) {
        guard settings.soundEnabled else { return }
        if settings.respectDND && Self.doNotDisturbEnabled { return }
        playBuffer(tone(for: event))
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            attached = true
        }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying { player.play() }
    }

    private func tone(for event: SoundEvent) -> AVAudioPCMBuffer {
        let sampleRate = 44_100.0
        let notes: [(Double, Double)] = event == .blocked ? [(880, 0.09), (1174, 0.13)] : [(784, 0.10), (523, 0.14)]
        let frames = notes.reduce(0) { $0 + Int($1.1 * sampleRate) }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        var offset = 0
        for (frequency, duration) in notes {
            let count = Int(duration * sampleRate)
            for n in 0..<count {
                let wave: Float = sin(2 * .pi * frequency * Double(n) / sampleRate) >= 0 ? 0.25 : -0.25
                let attack = min(1, Double(n) / (Double(count) * 0.1))
                let release = min(1, Double(count - n) / (Double(count) * 0.3))
                samples[offset + n] = wave * Float(min(attack, release))
            }
            offset += count
        }
        return buffer
    }

    private static var doNotDisturbEnabled: Bool {
        UserDefaults(suiteName: "com.apple.notificationcenterui")?.bool(forKey: "doNotDisturb") ?? false
    }
}
