import Testing
@testable import FidelisCore

@Suite struct MacBluetoothAudioTests {
    @Test func offNeedsAStringValue() {
        #expect(!MacBluetoothAudio.isOff(in: [:]))
        #expect(MacBluetoothAudio.isOff(in: ["a2dp": ["ServiceSettings": "FALSE"]]))
        #expect(MacBluetoothAudio.isOff(in: ["ServiceSettings": ["a2dp": "false"]]))
        // bluetoothd ignores a boolean.
        #expect(!MacBluetoothAudio.isOff(in: ["ServiceSettings": ["a2dp": false]]))
        #expect(!MacBluetoothAudio.isOff(in: ["ServiceSettings": ["a2dp": "TRUE"]]))
    }
}
