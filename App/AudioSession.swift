import AVFoundation

/// Single owner of the shared audio-session configuration. Both the speaker
/// (playback) and the recognizer (record) use `.playAndRecord` so switching
/// between speaking and listening never tears the session down and back up.
enum AudioSession {
    static func activatePlayAndRecord() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.duckOthers, .defaultToSpeaker,
                                          .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
