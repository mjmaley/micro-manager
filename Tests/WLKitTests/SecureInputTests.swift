import Foundation
import Testing
@testable import WLKit

struct SecureInputTests {
    @Test func startupRequiresValidation() {
        let gate = HardwareInputGate()
        #expect(!gate.accepts(gate.generation))
    }

    @Test func freshValidationEnablesInput() {
        var gate = HardwareInputGate()
        let accepted = gate.validated(gate.generation)
        #expect(accepted)
        #expect(gate.accepts(gate.generation))
    }

    @Test func enteringProtectionInvalidatesAcceptedInput() {
        var gate = HardwareInputGate()
        let before = gate.generation
        gate.validated(before)
        gate.observe(secureInput: true)
        #expect(!gate.ready)
        #expect(!gate.accepts(before))
        #expect(!gate.accepts(gate.generation))
    }

    @Test func protectionCannotBeValidatedAway() {
        var gate = HardwareInputGate()
        gate.observe(secureInput: true)
        let accepted = gate.validated(gate.generation)
        #expect(!accepted)
        #expect(!gate.ready)
    }

    @Test func clearingProtectionStillRequiresFreshValidation() {
        var gate = HardwareInputGate()
        gate.observe(secureInput: true)
        let paused = gate.generation
        gate.observe(secureInput: false)
        #expect(!gate.ready)
        let staleValidation = gate.validated(paused)
        #expect(!staleValidation)
        let freshValidation = gate.validated(gate.generation)
        #expect(freshValidation)
    }

    @Test func oldButtonsNeverReplayAfterRecovery() {
        var gate = HardwareInputGate()
        let press = gate.generation
        gate.validated(press)
        gate.observe(secureInput: true)
        gate.observe(secureInput: false)
        gate.validated(gate.generation)
        #expect(!gate.accepts(press))
        #expect(gate.accepts(gate.generation))
    }

    @Test func repeatedSamplesDoNotInvalidateHealthyInput() {
        var gate = HardwareInputGate()
        gate.validated(gate.generation)
        let token = gate.generation
        for _ in 0..<100 { gate.observe(secureInput: false) }
        #expect(gate.accepts(token))
    }

    @Test func longProtectedIntervalIsOneTransition() {
        var gate = HardwareInputGate()
        gate.observe(secureInput: true)
        let token = gate.generation
        for _ in 0..<100 { gate.observe(secureInput: true) }
        #expect(gate.generation == token)
        #expect(!gate.ready)
    }

    @Test func disconnectSleepAndStopInvalidatePendingValidation() {
        var gate = HardwareInputGate()
        let old = gate.generation
        gate.validated(old)
        gate.invalidate()
        let accepted = gate.validated(old)
        #expect(!accepted)
        #expect(!gate.accepts(old))
    }

    @Test func renewedProtectionInvalidatesRecoveryInFlight() {
        var gate = HardwareInputGate()
        gate.observe(secureInput: true)
        gate.observe(secureInput: false)
        let recovering = gate.generation
        gate.observe(secureInput: true)
        let accepted = gate.validated(recovering)
        #expect(!accepted)
        #expect(!gate.accepts(recovering))
    }

    @Test func physicalOpenIsBlockedBeforeDeviceDiscovery() {
        let device = WLDevice(secureInputIsActive: { true })
        var blocked = 0
        device.onSecureInputBlocked = { blocked += 1 }
        do {
            try device.connect()
            Issue.record("Expected protection to block connect")
        } catch {
            #expect(error.localizedDescription.contains("Secure Input"))
        }
        #expect(!device.isConnected)
        #expect(blocked == 1)
    }

    @Test func blockedCallDoesNotTransmitOrPretendItWasADriverError() {
        let device = WLDevice(secureInputIsActive: { true })
        var transmissions = 0
        var driverErrors = 0
        var completions = 0
        device.onTX = { _, _, _ in transmissions += 1 }
        device.onWriteError = { _, _ in driverErrors += 1 }
        let id = device.call("device.status", params: nil) { _, error in
            completions += 1
            #expect(error?.contains("Secure Input") == true)
        }
        #expect(id == nil)
        #expect(transmissions == 0)
        #expect(driverErrors == 0)
        #expect(completions == 1)
    }

    @Test func unprotectedMissingDeviceIsNotMislabeledSecureInput() {
        let device = WLDevice(secureInputIsActive: { false })
        let id = device.call("device.status", params: nil) { _, error in
            #expect(error == "Not connected.")
        }
        #expect(id == nil)
    }

    @Test func virtualPadDoesNotNeedPhysicalKeyboardAccess() async throws {
        let device = WLDevice(emulator: PadEmulator(), secureInputIsActive: { true })
        try device.connect()
        defer { device.disconnect(reason: nil) }
        let result = try await device.callAsync("device.status") as? [String: Any]
        #expect(result?["layer_index"] != nil)
    }
}
