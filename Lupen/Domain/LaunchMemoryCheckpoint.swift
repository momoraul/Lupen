//
//  LaunchMemoryCheckpoint.swift
//  Lupen
//
//  Created by jaden on 2026/06/07.
//

import Darwin
import Foundation

struct MemoryFootprint: Equatable, Sendable {
    let residentSizeBytes: UInt64
    let physicalFootprintBytes: UInt64

    static func current() -> MemoryFootprint? {
        guard let resident = currentResidentSizeBytes(),
              let footprint = currentPhysicalFootprintBytes() else {
            return nil
        }
        return MemoryFootprint(
            residentSizeBytes: resident,
            physicalFootprintBytes: footprint
        )
    }

    static func formattedBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }

    private static func currentResidentSizeBytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private static func currentPhysicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

enum LaunchMemoryCheckpoint {
    static func record(
        _ label: String,
        config: LaunchDiagnosticsConfig,
        metadata: [String: String] = [:],
        logger: LoggerService = .shared
    ) {
        guard config.memoryCheckpointsEnabled else { return }
        guard let footprint = MemoryFootprint.current() else {
            logger.logFromAnyThread(
                .warning,
                "Memory checkpoint [\(label)] unavailable",
                context: "Memory"
            )
            return
        }

        let suffix = metadata.isEmpty
            ? ""
            : " " + metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")

        let message = "Memory checkpoint [\(label)] rss=\(MemoryFootprint.formattedBytes(footprint.residentSizeBytes)) physical=\(MemoryFootprint.formattedBytes(footprint.physicalFootprintBytes))\(suffix)"
        logger.logFromAnyThread(.info, message, context: "Memory")
        fputs(message + "\n", stderr)
        fflush(stderr)
    }
}
