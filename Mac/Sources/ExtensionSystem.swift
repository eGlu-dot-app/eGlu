import AppKit
import Darwin
import PadCore
import WebKit

extension Extensions {
    func systemAPI(_ api: String, _ args: [Any], context: WKWebExtensionContext) throws -> Any? {
        let permission = api.hasPrefix("fontSettings.") ? "fontSettings" : api.split(separator: ".").prefix(2).joined(separator: ".")
        guard Self.asks(context, for: permission) else { throw Unanswered(why: "This extension does not have access to this system information.") }
        switch api {
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.sorted().map { ["fontId": $0, "displayName": $0] }
        case "system.memory.getInfo":
            var info = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
            }
            guard result == KERN_SUCCESS else { throw Unanswered(why: "Memory information is unavailable.") }
            return ["capacity": ProcessInfo.processInfo.physicalMemory,
                    "availableCapacity": UInt64(info.free_count + info.inactive_count) * UInt64(vm_kernel_page_size)]
        case "system.cpu.getInfo":
            var processorCount: natural_t = 0, info: processor_info_array_t?, count: mach_msg_type_number_t = 0
            guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &count) == KERN_SUCCESS,
                  let info else { throw Unanswered(why: "Processor information is unavailable.") }
            defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
            let scale = 1000 / Double(sysconf(_SC_CLK_TCK))
            let processors = (0..<Int(processorCount)).map { index -> [String: Any] in
                let base = index * Int(CPU_STATE_MAX)
                let user = Double(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])) * scale
                let system = Double(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])) * scale
                let idle = Double(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])) * scale
                let nice = Double(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])) * scale
                return ["usage": ["user": user + nice, "kernel": system, "idle": idle, "total": user + system + idle + nice]]
            }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            var size = 0
            sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
            var name = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
            return ["numOfProcessors": Int(processorCount), "archName": architecture, "modelName": String(cString: name),
                    "features": [], "processors": processors] as [String: Any]
        case "system.display.getInfo":
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            return NSScreen.screens.compactMap { screen -> [String: Any]? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let id = CGDirectDisplayID(number.uint32Value), bounds = CGDisplayBounds(id), size = CGDisplayScreenSize(id)
                func rect(_ rect: CGRect) -> [String: Int] { ["left": Int(rect.minX), "top": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)] }
                let visible = screen.visibleFrame
                let work = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
                return ["id": String(id), "name": screen.localizedName, "isPrimary": id == CGMainDisplayID(), "isInternal": CGDisplayIsBuiltin(id) != 0,
                        "isEnabled": true, "isUnified": false, "mirroringSourceId": "", "rotation": Int(CGDisplayRotation(id)),
                        "dpiX": size.width > 0 ? Double(CGDisplayPixelsWide(id)) / size.width * 25.4 : 0,
                        "dpiY": size.height > 0 ? Double(CGDisplayPixelsHigh(id)) / size.height * 25.4 : 0,
                        "bounds": rect(bounds), "workArea": rect(work)]
            }
        case "system.storage.getInfo":
            let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsRemovableKey, .volumeTotalCapacityKey]
            return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url -> [String: Any]? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return ["id": values.volumeUUIDString ?? url.path, "name": values.volumeName ?? url.lastPathComponent,
                        "type": values.volumeIsRemovable == true ? "removable" : "fixed", "capacity": values.volumeTotalCapacity ?? 0]
            }
        default: throw Unanswered(why: "This browser can read system information and list fonts. It cannot change display settings, eject disks, or change website fonts through an extension.")
        }
    }
}
