import Foundation
import CoreAudio

final class SystemAudioService: SystemAudioControlProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hanzo.system-audio")
    private let logger: LoggingServiceProtocol

    private struct MuteSnapshot {
        let deviceID: AudioDeviceID
    }

    private var activeSnapshot: MuteSnapshot?

    init(logger: LoggingServiceProtocol = LoggingService.shared) {
        self.logger = logger
    }

    func muteDefaultOutput() {
        queue.sync {
            guard activeSnapshot == nil else { return }
            guard let deviceID = Self.defaultOutputDeviceID() else {
                logger.warn("SystemAudioService: no default output device")
                return
            }
            guard Self.deviceSupportsMute(deviceID) else {
                logger.info("SystemAudioService: default output does not support mute; skipping")
                return
            }
            guard let alreadyMuted = Self.readMute(deviceID) else {
                logger.warn("SystemAudioService: failed to read mute state")
                return
            }
            if alreadyMuted {
                return
            }
            guard Self.writeMute(deviceID, muted: true) else {
                logger.warn("SystemAudioService: failed to mute default output")
                return
            }
            activeSnapshot = MuteSnapshot(deviceID: deviceID)
        }
    }

    func restoreDefaultOutput() {
        queue.sync {
            guard let snapshot = activeSnapshot else { return }
            activeSnapshot = nil
            if !Self.writeMute(snapshot.deviceID, muted: false) {
                logger.warn("SystemAudioService: failed to restore mute state")
            }
        }
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func deviceSupportsMute(_ deviceID: AudioDeviceID) -> Bool {
        var address = muteAddress()
        return AudioObjectHasProperty(deviceID, &address)
    }

    private static func readMute(_ deviceID: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    private static func writeMute(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return status == noErr
    }
}
