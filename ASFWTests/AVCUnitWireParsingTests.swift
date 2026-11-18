import Foundation
import Testing
@testable import ASFW

struct AVCUnitWireParsingTests {
    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var raw = value.littleEndian
        withUnsafeBytes(of: &raw) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    @Test func ensemblePhantomFCPFramesUseCorrectVendorAndMicIndex() {
        // Vendor-dependent AV/C CONTROL, Apogee OUI, E5 + mic 0..3.
        for microphone in 1...4 {
            for enabled in [false, true] {
                let expected = Data([0x00, 0xFF, 0x00, 0x00, 0x03, 0xDB,
                                     0xE5, UInt8(microphone - 1), enabled ? 1 : 0,
                                     0xFF, 0xFF, 0xFF])
                #expect(EnsemblePhantomPowerCommand.frame(
                    microphone: microphone, enabled: enabled
                ) == expected)
            }
        }
        #expect(EnsemblePhantomPowerCommand.frame(microphone: 0, enabled: true) == nil)
        #expect(EnsemblePhantomPowerCommand.frame(microphone: 5, enabled: true) == nil)
    }

    @Test func ensemblePhantomOnlyMatchesOriginalFireWireModel() {
        #expect(EnsemblePhantomPowerCommand.matches(vendorID: 0x0003DB, modelID: 0x01EEEE))
        #expect(!EnsemblePhantomPowerCommand.matches(vendorID: 0x0003DB, modelID: 0x01DDDD))
        #expect(!EnsemblePhantomPowerCommand.matches(vendorID: 0x000000, modelID: 0x01EEEE))
    }

    @Test func ensemblePhantomResponseMustBeAVCAcceptedAndMatchRequest() {
        let on = Data([0x09, 0xFF, 0x00, 0x00, 0x03, 0xDB,
                       0xE5, 0x00, 0x01, 0xFF, 0xFF, 0xFF])
        #expect(EnsemblePhantomPowerCommand.isAccepted(on, microphone: 1, enabled: true))
        #expect(!EnsemblePhantomPowerCommand.isAccepted(on, microphone: 1, enabled: false))
        #expect(!EnsemblePhantomPowerCommand.isAccepted(on, microphone: 2, enabled: true))
        var rejected = on
        rejected[0] = 0x0A // AV/C REJECTED, not a successful write
        #expect(!EnsemblePhantomPowerCommand.isAccepted(rejected, microphone: 1, enabled: true))
        var wrongVendor = on
        wrongVendor[5] = 0x00
        #expect(!EnsemblePhantomPowerCommand.isAccepted(wrongVendor, microphone: 1, enabled: true))
    }

    @Test func parses32BitVendorAndModelIDs() {
        var wire = Data()

        appendLE(UInt32(1), to: &wire) // unit count

        let guid: UInt64 = 0x0003_DB00_01DD_DD11
        appendLE(guid, to: &wire)
        appendLE(UInt16(0xFFC2), to: &wire)
        appendLE(UInt32(0x0003DB), to: &wire)
        appendLE(UInt32(0x01DDDD), to: &wire)

        wire.append(1)  // subunitCount
        wire.append(2)  // isoInputPlugs
        wire.append(2)  // isoOutputPlugs
        wire.append(0)  // extInputPlugs
        wire.append(0)  // extOutputPlugs
        wire.append(0)  // reserved

        wire.append(0x0C) // music subunit type
        wire.append(0x00) // subunit id
        wire.append(0x02) // num src plugs
        wire.append(0x02) // num dest plugs

        let units = ASFWDriverConnector.parseAVCUnitsWire(wire)
        #expect(units.count == 1)

        guard let unit = units.first else { return }
        #expect(unit.guid == guid)
        #expect(unit.nodeID == 0xFFC2)
        #expect(unit.vendorID == 0x0003DB)
        #expect(unit.modelID == 0x01DDDD)
        #expect(unit.isoInputPlugs == 2)
        #expect(unit.isoOutputPlugs == 2)
        #expect(unit.subunits.count == 1)
    }
}
