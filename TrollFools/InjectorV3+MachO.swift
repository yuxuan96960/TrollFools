//
//  InjectorV3+MachO.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import Foundation
import MachOKit
import OrderedCollections

extension InjectorV3 {
    func isMachO(_ target: URL) -> Bool {
        if (try? MachOKit.loadFromFile(url: target)) != nil {
            true
        } else {
            false
        }
    }

    func isProtectedMachO(_ target: URL) throws -> Bool {
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .encryptionInfo(encryptionInfoCommand):
                    if encryptionInfoCommand.cryptid != 0 {
                        return true
                    }
                case let .encryptionInfo64(encryptionInfoCommand):
                    if encryptionInfoCommand.cryptid != 0 {
                        return true
                    }
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .encryptionInfo(encryptionInfoCommand):
                        if encryptionInfoCommand.cryptid != 0 {
                            return true
                        }
                    case let .encryptionInfo64(encryptionInfoCommand):
                        if encryptionInfoCommand.cryptid != 0 {
                            return true
                        }
                    default:
                        continue
                    }
                }
            }
        }
        return false
    }

    func linkedDylibsRecursivelyOfMachO(_ target: URL, collected: OrderedSet<URL> = []) throws -> OrderedSet<URL> {
        if collected.contains(target) {
            return collected
        }

        var newCollected = collected
        newCollected.append(target)

        // If the Mach-O has a backup (made before injection), read load commands
        // from the original to avoid picking up previously-injected dylibs.
        let readTarget = hasAlternate(target) ? Self.alternateURL(for: target) : target
        let loadedDylibs = try loadedDylibsOfMachO(readTarget).compactMap({ resolveLoadCommand($0) })
        for dylib in loadedDylibs {
            newCollected = try linkedDylibsRecursivelyOfMachO(dylib, collected: newCollected)
        }

        return newCollected
    }

    func loadedDylibsOfMachO(_ target: URL) throws -> OrderedSet<String> {
        var dylibs = OrderedSet<String>()
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .loadDylib(loadDylibCommand):
                    dylibs.append(loadDylibCommand.dylib(in: machOFile).name)
                case let .loadWeakDylib(loadWeakDylibCommand):
                    dylibs.append(loadWeakDylibCommand.dylib(in: machOFile).name)
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .loadDylib(loadDylibCommand):
                        dylibs.append(loadDylibCommand.dylib(in: machOFile).name)
                    case let .loadWeakDylib(loadWeakDylibCommand):
                        dylibs.append(loadWeakDylibCommand.dylib(in: machOFile).name)
                    default:
                        continue
                    }
                }
            }
        }
        return dylibs
    }

    func runtimePathsOfMachO(_ target: URL) throws -> OrderedSet<String> {
        var paths = OrderedSet<String>()
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .rpath(rpathCommand):
                    paths.append(rpathCommand.path(in: machOFile))
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .rpath(rpathCommand):
                        paths.append(rpathCommand.path(in: machOFile))
                    default:
                        continue
                    }
                }
            }
        }
        return paths
    }

    func teamIdentifierOfMachO(_ target: URL) throws -> String? {
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            if let codeSign = machOFile.codeSign, let teamID = codeSign.codeDirectory?.teamId(in: codeSign) {
                return teamID
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                if let codeSign = machOFile.codeSign, let teamID = codeSign.codeDirectory?.teamId(in: codeSign) {
                    return teamID
                }
            }
        }
        return nil
    }

    fileprivate func resolveLoadCommand(_ name: String) -> URL? {
        guard (name.hasPrefix("@rpath/") && !name.hasPrefix("@rpath/libswift")) || name.hasPrefix("@executable_path/") else {
            return nil
        }

        var resolvedName = name
        resolvedName = resolvedName
            .replacingOccurrences(of: "@executable_path/", with: executableURL.deletingLastPathComponent().path + "/")
        resolvedName = resolvedName
            .replacingOccurrences(of: "@rpath/", with: frameworksDirectoryURL.path + "/")

        let resolvedURL = URL(fileURLWithPath: resolvedName)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return resolvedURL
    }
}

// MARK: - Structure Inspection

struct MachOStructureEntry: Identifiable {
    let id: String
    let url: URL
    let relativePath: String
    let architectures: [String]
    let isEncrypted: Bool
    let isMainExecutable: Bool
    let fileSize: Int64
    let loadedDylibs: [String]
    let runtimePaths: [String]
    let hasBackup: Bool

    var architecturesDescription: String {
        architectures.isEmpty ? NSLocalizedString("Unknown", comment: "") : architectures.joined(separator: ", ")
    }

    var fileSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct BundleStructureReport {
    let bundleURL: URL
    let entries: [MachOStructureEntry]
}

extension InjectorV3 {
    /// Reads the CPU architecture list of a Mach-O file without loading it into memory.
    func architecturesOfMachO(_ target: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: target) else {
            return []
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else {
            return []
        }

        let bytes = [UInt8](data)

        func bigEndian(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else {
                return nil
            }
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }

        func littleEndian(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else {
                return nil
            }
            return UInt32(bytes[offset + 3]) << 24
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset])
        }

        guard let magic = bigEndian(0) else {
            return []
        }

        switch magic {
        case 0xFEED_FACE, 0xFEED_FACF:
            guard let cpuType = littleEndian(4), let cpuSubtype = littleEndian(8) else {
                return []
            }
            return [Self.cpuTypeDescription(cpuType: cpuType, cpuSubtype: cpuSubtype)]

        case 0xCEFA_EDFE, 0xCFFA_EDFE:
            guard let cpuType = bigEndian(4), let cpuSubtype = bigEndian(8) else {
                return []
            }
            return [Self.cpuTypeDescription(cpuType: cpuType, cpuSubtype: cpuSubtype)]

        case 0xCAFE_BABE, 0xCAFE_BABF:
            guard let count = bigEndian(4) else {
                return []
            }

            let entrySize = (magic == 0xCAFE_BABF) ? 32 : 20
            var architectures = [String]()
            for index in 0 ..< Int(min(count, 16)) {
                let offset = 8 + index * entrySize
                guard let cpuType = bigEndian(offset), let cpuSubtype = bigEndian(offset + 4) else {
                    break
                }
                architectures.append(Self.cpuTypeDescription(cpuType: cpuType, cpuSubtype: cpuSubtype))
            }
            return architectures

        default:
            return []
        }
    }

    /// Every Mach-O that lives directly inside the `Frameworks` directory of the target bundle.
    /// Bare dylibs are returned as-is, frameworks are resolved to their executable file.
    func machOsInFrameworksDirectory() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: frameworksDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls = [URL]()
        for item in contents {
            if item.pathExtension.lowercased() == "framework" {
                if let executableURL = try? locateExecutableInBundle(item), isMachO(executableURL) {
                    urls.append(executableURL)
                }
                continue
            }
            if isMachO(item) {
                urls.append(item)
            }
        }

        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Mach-O entries of the main executable plus everything inside `Frameworks`.
    func structureEntriesInBundle() -> [MachOStructureEntry] {
        var urls = [URL]()
        if isMachO(executableURL) {
            urls.append(executableURL)
        }
        urls.append(contentsOf: machOsInFrameworksDirectory())

        var seen = Set<String>()
        var entries = [MachOStructureEntry]()
        for url in urls where !seen.contains(url.path) {
            seen.insert(url.path)
            if let entry = structureEntry(for: url) {
                entries.append(entry)
            }
        }
        return entries
    }

    func structureEntry(for url: URL) -> MachOStructureEntry? {
        guard isMachO(url) else {
            return nil
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let prefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
        let relativePath = url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent

        let loadedDylibs: [String] = (try? loadedDylibsOfMachO(url)).map { Array($0.elements) } ?? []
        let runtimePaths: [String] = (try? runtimePathsOfMachO(url)).map { Array($0.elements) } ?? []

        return MachOStructureEntry(
            id: url.path,
            url: url,
            relativePath: relativePath,
            architectures: architecturesOfMachO(url),
            isEncrypted: (try? isProtectedMachO(url)) ?? false,
            isMainExecutable: url.path == executableURL.path,
            fileSize: Int64(fileSize),
            loadedDylibs: loadedDylibs,
            runtimePaths: runtimePaths,
            hasBackup: hasAlternate(url)
        )
    }

    fileprivate static func cpuTypeDescription(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C:
            return cpuSubtype == 2 ? "arm64e" : "arm64"
        case 0x0000_000C:
            return "armv7"
        case 0x0100_0007:
            return "x86_64"
        case 0x0000_0007:
            return "i386"
        default:
            return String(format: "cpu(0x%08X)", cpuType)
        }
    }
}
