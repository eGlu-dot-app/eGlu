import AVFoundation
import PadCore
import WebKit

@MainActor
final class ExtensionSpeech: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private static var speakers: [String: ExtensionSpeech] = [:]
    private let synthesizer = AVSpeechSynthesizer()
    private let extensionID: String
    private let space: UUID
    private var tokens: [ObjectIdentifier: String] = [:]

    private init(id: String, space: UUID) {
        extensionID = id
        self.space = space
        super.init()
        synthesizer.delegate = self
    }

    static func close(_ id: String, in space: UUID) {
        speakers.removeValue(forKey: "\(space.uuidString)/\(id)")?.synthesizer.stopSpeaking(at: .immediate)
    }

    static func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) throws -> Any? {
        guard Extensions.asks(context, for: "tts") else { throw Extensions.Unanswered(why: "This extension does not have speech access.") }
        let key = "\(space.uuidString)/\(context.uniqueIdentifier)"
        let speaker = speakers[key] ?? ExtensionSpeech(id: context.uniqueIdentifier, space: space)
        speakers[key] = speaker
        switch api {
        case "tts.getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map { ["voiceName": $0.name, "lang": $0.language, "remote": false,
                                                              "eventTypes": ["start", "end", "interrupted", "word", "pause", "resume"]] as [String: Any] }
        case "tts.isSpeaking": return speaker.synthesizer.isSpeaking
        case "tts.stop": speaker.synthesizer.stopSpeaking(at: .immediate); return nil
        case "tts.pause": speaker.synthesizer.pauseSpeaking(at: .immediate); return nil
        case "tts.resume": speaker.synthesizer.continueSpeaking(); return nil
        case "tts.speak":
            guard let text = args.first as? String, text.utf8.count <= 65_536 else { throw Extensions.Unanswered(why: "Speech text must be at most 65,536 bytes.") }
            let options = args.dropFirst().first as? [String: Any] ?? [:]
            guard options["extensionId"] == nil else { throw Extensions.Unanswered(why: "This browser cannot use another extension as a speech engine.") }
            let utterance = AVSpeechUtterance(string: text)
            if let name = options["voiceName"] as? String {
                guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) else { throw Extensions.Unanswered(why: "The requested voice is not installed on this Mac.") }
                utterance.voice = voice
            } else if let language = options["lang"] as? String { utterance.voice = AVSpeechSynthesisVoice(language: language) }
            let rate = (options["rate"] as? NSNumber)?.floatValue ?? 1
            let pitch = (options["pitch"] as? NSNumber)?.floatValue ?? 1
            let volume = (options["volume"] as? NSNumber)?.floatValue ?? 1
            guard rate.isFinite, pitch.isFinite, volume.isFinite, (0.1...10).contains(rate), (0...2).contains(pitch), (0...1).contains(volume) else {
                throw Extensions.Unanswered(why: "Invalid speech rate, pitch, or volume.")
            }
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate))
            utterance.pitchMultiplier = max(0.5, pitch)
            utterance.volume = volume
            if options["enqueue"] as? Bool != true { speaker.synthesizer.stopSpeaking(at: .immediate) }
            if let token = options["__egluSpeech"] as? String { speaker.tokens[ObjectIdentifier(utterance)] = token }
            speaker.synthesizer.speak(utterance)
            return nil
        default: throw Extensions.Unanswered(why: "This speech action is unavailable.")
        }
    }

    private func tell(_ type: String, utterance: AVSpeechUtterance, index: Int = 0, done: Bool = false) {
        let key = ObjectIdentifier(utterance)
        guard let token = tokens[key] else { return }
        ExtensionEvents.shared.send("tts.onEvent", arguments: [token, ["type": type, "charIndex": index]], to: extensionID, in: space)
        if done { tokens[key] = nil }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { tell("start", utterance: utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { tell("end", utterance: utterance, index: utterance.speechString.utf16.count, done: true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { tell("interrupted", utterance: utterance, done: true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) { tell("pause", utterance: utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) { tell("resume", utterance: utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) { tell("word", utterance: utterance, index: characterRange.location) }
}
