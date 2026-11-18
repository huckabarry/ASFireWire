//
//  AVCCommandView.swift
//  ASFW
//
//  AV/C command sender with preset builder and raw FCP hex mode.
//

import SwiftUI

/// An opt-in, model-gated prototype of the original Ensemble's vendor AV/C
/// phantom-power command. This creates bytes only; it never sends on its own.
/// The 48V LED on the hardware is the verification source until a reliable
/// Ensemble state-read protocol has been implemented.
enum EnsemblePhantomPowerCommand {
    static let vendorID: UInt32 = 0x0003DB
    static let modelID: UInt32 = 0x01EEEE

    static func matches(vendorID: UInt32, modelID: UInt32) -> Bool {
        vendorID == Self.vendorID && modelID == Self.modelID
    }

    static func frame(microphone: Int, enabled: Bool) -> Data? {
        guard (1...4).contains(microphone) else { return nil }
        // AV/C CONTROL, UNIT, VENDOR_DEPENDENT, Apogee OUI 00:03:DB.
        // Ensemble command E5, zero-based mic index, Boolean, FF padding.
        // Reference: ALSA snd-firewire-ctl-services bebob/apogee/ensemble.rs
        // EnsembleOperation::build_operands and EnsembleCmd::MicPower.
        return Data([0x00, 0xFF, 0x00, 0x00, 0x03, 0xDB,
                     0xE5, UInt8(microphone - 1), enabled ? 1 : 0,
                     0xFF, 0xFF, 0xFF])
    }

    /// AV/C acceptance means the command was accepted, NOT that 48V was
    /// independently read back from the device. Verify the front-panel LED.
    static func isAccepted(_ response: Data, microphone: Int, enabled: Bool) -> Bool {
        guard let frame = frame(microphone: microphone, enabled: enabled),
              response.count >= 6,
              response[0] == 0x09, response[1] == 0xFF, response[2] == 0x00,
              response[3] == 0x00, response[4] == 0x03, response[5] == 0xDB else {
            return false
        }
        // Some AV/C replies carry only header/company ID. If the command is
        // echoed, it must match the command we actually requested.
        return response.count < 9 || response[6..<9].elementsEqual(frame[6..<9])
    }
}

struct AVCCommandView: View {
    @ObservedObject var viewModel: DebugViewModel

    @State private var avcUnits: [ASFWDriverConnector.AVCUnitInfo] = []
    @State private var selectedUnitGUID: UInt64?

    @State private var commandTab: CommandTab = .presetBuilder

    @State private var commandType: FCPCommandType = .status
    @State private var subunitType: String = "1F"
    @State private var subunitID: String = "7"
    @State private var opcode: String = "31"
    @State private var operands: String = "07FFFFFF"

    @State private var rawCommandHex: String = "01 FF 31 07 FF FF FF FF"

    // The original Ensemble has four software-controlled 48V microphone inputs.
    // No inferred/stored ON state: only the actual hardware LED verifies a write.
    @State private var pendingPhantomMicrophone = 1
    @State private var pendingPhantomEnable = false
    @State private var showPhantomConfirmation = false
    @State private var phantomSending = false
    @State private var phantomResult: String?

    @State private var isSending = false
    @State private var lastResponseData: Data?
    @State private var lastResponseSummary: String?
    @State private var lastError: String?
    @State private var lastSentTime: Date?

    enum CommandTab: String, CaseIterable {
        case presetBuilder = "Preset Builder"
        case rawHex = "Raw Hex"
    }

    enum FCPCommandType: String, CaseIterable {
        case control = "CONTROL (0x00)"
        case status = "STATUS (0x01)"
        case inquiry = "INQUIRY (0x02)"
        case notify = "NOTIFY (0x03)"

        var ctype: UInt8 {
            switch self {
            case .control: return 0x00
            case .status: return 0x01
            case .inquiry: return 0x02
            case .notify: return 0x03
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack {
                        if viewModel.isConnected {
                            Label("Connected to driver", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Driver not connected", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }

                        Spacer()

                        Button {
                            refreshUnits()
                        } label: {
                            Label("Refresh Units", systemImage: "arrow.clockwise")
                        }
                        .disabled(!viewModel.isConnected)
                    }
                } label: {
                    Label("Status", systemImage: "info.circle")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select AV/C Unit")
                            .font(.subheadline.bold())

                        if avcUnits.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No AV/C units detected")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Picker("Unit", selection: $selectedUnitGUID) {
                                Text("Select unit...").tag(nil as UInt64?)
                                ForEach(avcUnits) { unit in
                                    Text("GUID: \(unit.guidHex) (Node: \(unit.nodeIDHex))")
                                        .tag(unit.guid as UInt64?)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                } label: {
                    Label("Target Unit", systemImage: "target")
                        .font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Mode", selection: $commandTab) {
                            ForEach(CommandTab.allCases, id: \.rawValue) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if commandTab == .presetBuilder {
                            presetBuilderSection
                        } else {
                            rawHexSection
                        }
                    }
                } label: {
                    Label("AV/C Command", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                }

                if lastResponseData != nil || lastError != nil {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if let time = lastSentTime {
                                Text("Sent: \(time.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let summary = lastResponseSummary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let responseData = lastResponseData {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("FCP Response (\(responseData.count) bytes):")
                                        .font(.caption.bold())
                                    Text(hexString(responseData))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.green)
                                        .textSelection(.enabled)
                                }
                            }

                            if let error = lastError {
                                HStack {
                                    Image(systemName: "xmark.octagon.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    } label: {
                        Label("Result", systemImage: "arrow.down.circle")
                            .font(.headline)
                    }
                }

                Button {
                    sendCommand()
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.regular)
                            .padding(.trailing, 8)
                        Text("Sending...")
                    } else {
                        Label("Send FCP Command", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || phantomSending || !viewModel.isConnected || selectedUnitGUID == nil)
                .controlSize(.large)

                if selectedEnsembleUnit != nil {
                    ensemblePhantomSection
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle("AV/C Commands")
        .alert("Send Ensemble 48V command?", isPresented: $showPhantomConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button(pendingPhantomEnable ? "Enable 48V" : "Disable 48V") {
                sendEnsemblePhantom()
            }
        } message: {
            Text("Mic \(pendingPhantomMicrophone): this changes physical 48V power. Stop recording and mute monitors. For the initial test disconnect microphones; never test with a ribbon microphone attached. Confirm the 48V LED on the Ensemble after the command.")
        }
        .onAppear {
            if viewModel.isConnected {
                refreshUnits()
            }
        }
    }

    // MARK: - Original Apogee Ensemble (experimental hardware control)

    private var selectedEnsembleUnit: ASFWDriverConnector.AVCUnitInfo? {
        guard let guid = selectedUnitGUID else { return nil }
        return avcUnits.first {
            $0.guid == guid &&
                EnsemblePhantomPowerCommand.matches(vendorID: $0.vendorID, modelID: $0.modelID)
        }
    }

    private var ensemblePhantomSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Experimental: independently controlled 48V on mic inputs 1–4. This uses the Ensemble-specific Apogee AV/C command, not the Duet control. These buttons never run automatically.")
                    .font(.callout)
                Text("This build cannot read the 48V state back. A successful AV/C reply is not proof that phantom power changed; verify the corresponding front-panel LED. Inputs must already be in microphone mode.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                ForEach(1...4, id: \.self) { microphone in
                    HStack(spacing: 12) {
                        Text("Mic \(microphone)")
                            .frame(width: 70, alignment: .leading)
                        Button("48V On") { prepareEnsemblePhantom(microphone, enabled: true) }
                            .disabled(phantomSending || isSending || !viewModel.isConnected)
                        Button("48V Off") { prepareEnsemblePhantom(microphone, enabled: false) }
                            .disabled(phantomSending || isSending || !viewModel.isConnected)
                        Spacer()
                    }
                }
                if phantomSending { ProgressView("Waiting for AV/C response…") }
                if let phantomResult {
                    Text(phantomResult).font(.callout)
                        .textSelection(.enabled)
                }
            }
        } label: {
            Label("Ensemble — Phantom Power (experimental)", systemImage: "bolt.badge.a")
        }
    }

    private func prepareEnsemblePhantom(_ microphone: Int, enabled: Bool) {
        guard selectedEnsembleUnit != nil, !phantomSending else { return }
        pendingPhantomMicrophone = microphone
        pendingPhantomEnable = enabled
        showPhantomConfirmation = true
    }

    private func sendEnsemblePhantom() {
        guard let unit = selectedEnsembleUnit,
              let frame = EnsemblePhantomPowerCommand.frame(
                microphone: pendingPhantomMicrophone, enabled: pendingPhantomEnable
              ), !phantomSending else { return }

        let guid = unit.guid
        let microphone = pendingPhantomMicrophone
        let enabled = pendingPhantomEnable
        phantomSending = true
        phantomResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            // Revalidate identity immediately before sending; a stale selection
            // must never cause a 48V command to reach a different AV/C device.
            let current = self.viewModel.connector.getAVCUnits()?.first { $0.guid == guid }
            guard let current, EnsemblePhantomPowerCommand.matches(
                vendorID: current.vendorID, modelID: current.modelID
            ) else {
                DispatchQueue.main.async {
                    self.phantomSending = false
                    self.phantomResult = "No matching Ensemble attached. No command sent."
                }
                return
            }

            let response = self.viewModel.connector.sendRawFCPCommand(guid: guid, frame: frame)
            DispatchQueue.main.async {
                self.phantomSending = false
                if let response {
                    let responseHex = self.hexString(response)
                    if EnsemblePhantomPowerCommand.isAccepted(
                        response, microphone: microphone, enabled: enabled
                    ) {
                        self.phantomResult = "Mic \(microphone): 48V \(enabled ? "ON" : "OFF") command ACCEPTED. Verify the matching LED before assuming power changed. Response: \(responseHex)"
                    } else {
                        self.phantomResult = "Mic \(microphone): unexpected/refused AV/C response. Do not assume 48V changed. Response: \(responseHex)"
                    }
                } else {
                    self.phantomResult = "Mic \(microphone): transport error or timeout. Do not assume 48V changed. See System Logs."
                }
            }
        }
    }

    private var presetBuilderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command Type (ctype)")
                    .font(.subheadline.bold())
                Picker("", selection: $commandType) {
                    ForEach(FCPCommandType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subunit Type")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("0x")
                            .foregroundColor(.secondary)
                        TextField("1F", text: $subunitType)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Subunit ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("7", text: $subunitID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80)
                }
            }

            Text("Common: 0x1F (unit) + ID 7 (broadcast)")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Opcode")
                    .font(.subheadline.bold())
                HStack {
                    Text("0x")
                        .foregroundColor(.secondary)
                    TextField("31", text: $opcode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80)
                }
                Text("Example: 0x31 (SUBUNIT_INFO), 0x30 (UNIT_INFO)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Operands (hex bytes)")
                    .font(.subheadline.bold())
                TextEditor(text: $operands)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                Text("Enter hex bytes (optional spaces/newlines): 07 FF FF FF")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Commands")
                    .font(.caption.bold())
                HStack(spacing: 8) {
                    Button("SUBUNIT_INFO") {
                        setSubunitInfo()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("UNIT_INFO") {
                        setUnitInfo()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let preview = buildFCPCommand() {
                Text("Frame Preview: \(hexString(preview))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Frame Preview: invalid fields")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
    }

    private var rawHexSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Raw FCP frame bytes")
                .font(.subheadline.bold())
            TextEditor(text: $rawCommandHex)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            Text("Enter full FCP command frame (3-512 bytes). Example: 01 FF 31 07 FF FF FF FF")
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack {
                Button("Load Preset Frame") {
                    if let preview = buildFCPCommand() {
                        rawCommandHex = hexString(preview)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if let byteCount = parseHexBytes(rawCommandHex)?.count {
                    Text("\(byteCount) bytes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Invalid hex")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func refreshUnits() {
        guard viewModel.isConnected else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let units = viewModel.connector.getAVCUnits() ?? []
            DispatchQueue.main.async {
                self.avcUnits = units
                if let first = units.first {
                    self.selectedUnitGUID = first.guid
                }
            }
        }
    }

    private func sendCommand() {
        guard let guid = selectedUnitGUID else { return }

        let commandData: Data?
        switch commandTab {
        case .presetBuilder:
            commandData = buildFCPCommand()
        case .rawHex:
            commandData = parseHexBytes(rawCommandHex)
        }

        guard let commandData else {
            lastError = "Invalid command format"
            lastResponseData = nil
            lastResponseSummary = nil
            return
        }

        isSending = true
        lastError = nil
        lastResponseData = nil
        lastResponseSummary = nil
        lastSentTime = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let response = viewModel.connector.sendRawFCPCommand(guid: guid, frame: commandData)

            DispatchQueue.main.async {
                self.isSending = false
                if let response {
                    self.lastResponseData = response
                    self.lastResponseSummary = self.responseSummary(response)
                    self.lastError = nil
                } else {
                    self.lastError = viewModel.connector.lastError ?? "Failed to send FCP command"
                    self.lastResponseData = nil
                    self.lastResponseSummary = nil
                }
            }
        }
    }

    private func buildFCPCommand() -> Data? {
        guard let subunitTypeVal = UInt8(subunitType.cleanedHexString, radix: 16) else { return nil }
        guard let subunitIDVal = parseUInt8(subunitID), subunitIDVal <= 0x07 else { return nil }
        guard let opcodeVal = UInt8(opcode.cleanedHexString, radix: 16) else { return nil }
        guard let operandBytes = parseHexBytes(operands, minBytes: 0, maxBytes: 509) else { return nil }

        var frame = Data()
        frame.append(commandType.ctype)
        frame.append((subunitTypeVal << 3) | (subunitIDVal & 0x7))
        frame.append(opcodeVal)
        frame.append(operandBytes)

        while frame.count < 8 {
            frame.append(0xFF)
        }

        return frame
    }

    private func parseUInt8(_ value: String) -> UInt8? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt8(trimmed.dropFirst(2), radix: 16)
        }
        if let decimal = UInt8(trimmed, radix: 10) {
            return decimal
        }
        return UInt8(trimmed, radix: 16)
    }

    private func parseHexBytes(_ value: String, minBytes: Int = 3, maxBytes: Int = 512) -> Data? {
        let cleaned = value.cleanedHexString
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        guard data.count >= minBytes && data.count <= maxBytes else { return nil }
        return data
    }

    private func responseSummary(_ response: Data) -> String {
        guard response.count >= 3 else {
            return "Response received (\(response.count) bytes)"
        }

        let ctype = response[0]
        let subunit = response[1]
        let opcodeValue = response[2]
        let operandCount = response.count - 3

        return String(
            format: "ctype=0x%02X (%@), subunit=0x%02X, opcode=0x%02X, operands=%u",
            ctype,
            responseTypeName(ctype),
            subunit,
            opcodeValue,
            UInt32(operandCount)
        )
    }

    private func responseTypeName(_ ctype: UInt8) -> String {
        switch ctype {
        case 0x08: return "NOT_IMPLEMENTED"
        case 0x09: return "ACCEPTED"
        case 0x0A: return "REJECTED"
        case 0x0B: return "IN_TRANSITION"
        case 0x0C: return "IMPLEMENTED/STABLE"
        case 0x0D: return "CHANGED"
        case 0x0F: return "INTERIM"
        default: return "UNKNOWN"
        }
    }

    private func setSubunitInfo() {
        commandType = .status
        subunitType = "1F"
        subunitID = "7"
        opcode = "31"
        operands = "07FFFFFF"
    }

    private func setUnitInfo() {
        commandType = .status
        subunitType = "1F"
        subunitID = "7"
        opcode = "30"
        operands = "07FFFFFF"
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private extension String {
    var cleanedHexString: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }
}

#Preview {
    AVCCommandView(viewModel: DebugViewModel())
}
