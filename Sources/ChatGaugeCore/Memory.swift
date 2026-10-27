import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum MemoryStats {
    /// Free + inactive + purgeable bytes (what macOS can hand to a new model without swapping hard).
    public static func availableBytes() -> Int64 {
        #if canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)
        return pages * Int64(page)
        #else
        return 0
        #endif
    }

    public static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
