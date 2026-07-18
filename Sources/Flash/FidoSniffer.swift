import Foundation
import IOKit.hid

/// Sniffs CTAPHID traffic on any FIDO security key (Titan, YubiKey, …) by
/// opening the key's HID interface non-exclusively, alongside whichever app
/// actually owns it. Watches for keepalive packets with status UP_NEEDED —
/// the exact "touch your key now" signal from the CTAP spec — and for the
/// response packet that means the touch happened (or the request died).
final class FidoSniffer {

    static let shared = FidoSniffer()

    /// Called on the main runloop.
    var onTouchNeeded: (() -> Void)?
    /// `true` = the key was touched / request answered. `false` = cancelled or key unplugged.
    var onTouchResolved: ((Bool) -> Void)?

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var waiting = false

    // FIDO HID usage page / usage (same for every FIDO1/2 key).
    private let usagePageFIDO = 0xF1D0
    private let usageFIDO = 0x01

    // CTAPHID init-packet command bytes (already OR'd with the 0x80 flag).
    private let cmdCBOR: UInt8 = 0x90      // CTAPHID_CBOR  — request/response body
    private let cmdMSG: UInt8 = 0x83       // CTAPHID_MSG   — U2F APDU body
    private let cmdKeepalive: UInt8 = 0xBB // CTAPHID_KEEPALIVE
    private let cmdError: UInt8 = 0xBF     // CTAPHID_ERROR — cancel/failure
    private let statusUPNeeded: UInt8 = 0x02

    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: usagePageFIDO,
            kIOHIDDeviceUsageKey: usageFIDO
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<FidoSniffer>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<FidoSniffer>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        log(result == kIOReturnSuccess ? "manager open, listening for FIDO keys" : "manager open failed: \(result)")
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
        waiting = false
        log("stopped")
    }

    private func attach(_ device: IOHIDDevice) {
        guard !devices.contains(device) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log("device open failed: \(result)")
            return
        }
        devices.append(device)

        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "FIDO key"
        log("sniffing: \(name)")

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers.append(buffer)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            Unmanaged<FidoSniffer>.fromOpaque(ctx).takeUnretainedValue().handleReport(report, length: length)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func detach(_ device: IOHIDDevice) {
        devices.removeAll { $0 == device }
        log("key unplugged")
        if devices.isEmpty && waiting {
            waiting = false
            onTouchResolved?(false)
        }
    }

    private func handleReport(_ report: UnsafePointer<UInt8>, length: Int) {
        // Packet layout: CID(4) CMD(1) BCNT(2) DATA(...). Some stacks prefix
        // a report-ID byte — if offset 4 doesn't hold a flagged command byte
        // but the first byte is 0, retry one byte in.
        var base = 0
        if length >= 9, report[0] == 0, report[5] & 0x80 != 0, report[4] & 0x80 == 0 {
            base = 1
        }
        guard length >= base + 8 else { return }

        let cmd = report[base + 4]
        guard cmd & 0x80 != 0 else { return } // continuation packets don't interest us

        switch cmd {
        case cmdKeepalive:
            let status = report[base + 7]
            if status == statusUPNeeded, !waiting {
                waiting = true
                log("UP_NEEDED — touch requested ⚡")
                onTouchNeeded?()
            }
        case cmdCBOR, cmdMSG:
            if waiting {
                waiting = false
                log("response received — touch done ✅")
                onTouchResolved?(true)
            }
        case cmdError:
            if waiting {
                waiting = false
                log("request cancelled")
                onTouchResolved?(false)
            }
        default:
            break
        }
    }

    private func log(_ message: String) {
        Log.write("[sniffer] \(message)")
    }
}
