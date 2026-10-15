//
//  InjectorV3+Inject.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    enum Strategy: String, CaseIterable {
        case lexicographic
        case fast
        case preorder
        case postorder

        var localizedDescription: String {
            switch self {
            case .lexicographic: NSLocalizedString("Lexicographic", comment: "")
            case .fast: NSLocalizedString("Fast", comment: "")
            case .preorder: NSLocalizedString("Pre-order", comment: "")
            case .postorder: NSLocalizedString("Post-order", comment: "")
            }
        }
    }

    // MARK: - Instance Methods

    func inject(_ assetURLs: [URL], shouldPersist: Bool) throws {
        didUseMachOEnumerationFallback = false
        let preparedAssetURLs = try preprocessAssets(assetURLs)

        precondition(!preparedAssetURLs.isEmpty, "No asset to inject.")
        terminateApp()

        try injectBundles(preparedAssetURLs
            .filter { $0.pathExtension.lowercased() == "bundle" })

        try injectDylibsAndFrameworks(preparedAssetURLs
            .filter { $0.pathExtension.lowercased() == "dylib" || $0.pathExtension.lowercased() == "framework" })

        if shouldPersist {
            try persist(preparedAssetURLs)
        }
    }

    // MARK: - Private Methods

    fileprivate func injectBundles(_ assetURLs: [URL]) throws {
        guard !assetURLs.isEmpty else {
            return
        }

        for assetURL in assetURLs {
            let targetURL = bundleURL.appendingPathComponent(assetURL.lastPathComponent)

            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: true)
        }
    }

    fileprivate func injectDylibsAndFrameworks(_ assetURLs: [URL]) throws {
        guard !assetURLs.isEmpty else {
            return
        }

        try assetURLs.forEach {
            try standardizeLoadCommandDylibToSubstrate($0)
            try applyCoreTrustBypass($0)
        }

        let substrateFwkURL = try prepareSubstrate()
        guard let targetMachO = try locateAvailableMachO() else {
            DDLogError("All Mach-Os are protected", ddlog: logger)

            throw Error.generic(NSLocalizedString("No eligible framework found.\n\nIt is usually not a bug with TrollFools itself, but rather with the target app. You may re-install that from App Store. You can’t use TrollFools with apps installed via “Asspp” or tweaks like “NoAppThinning”.", comment: ""))
        }

        DDLogInfo("Best matched Mach-O is \(targetMachO.path)", ddlog: logger)

        let resourceURLs: [URL] = [substrateFwkURL] + assetURLs
        try makeAlternate(targetMachO)
        do {
            try copyfiles(resourceURLs)
            for assetURL in assetURLs {
                try insertLoadCommandOfAsset(assetURL, to: targetMachO)
            }
            try applyCoreTrustBypass(targetMachO)
        } catch {
            try? restoreAlternate(targetMachO)
            try? batchRemove(resourceURLs)
            throw error
        }
    }

    // MARK: - Core Trust

    fileprivate func applyCoreTrustBypass(_ target: URL) throws {
        let isFramework = checkIsBundle(target)

        let machO: URL
        if isFramework {
            machO = try locateExecutableInBundle(target)
        } else {
            machO = target
        }

        try cmdCoreTrustBypass(machO, teamID: teamID)
        try cmdChangeOwnerToInstalld(target, recursively: isFramework)
    }

    // MARK: - Cydia Substrate

    fileprivate static let substrateZipURL = findResource(substrateFwkName, fileExtension: "zip")

    fileprivate func prepareSubstrate() throws -> URL {
        try FileManager.default.unzipItem(at: Self.substrateZipURL, to: temporaryDirectoryURL)

        let fwkURL = temporaryDirectoryURL.appendingPathComponent(Self.substrateFwkName)
        try markBundlesAsInjected([fwkURL], privileged: false)

        let machO = fwkURL.appendingPathComponent(Self.substrateName)

        try cmdCoreTrustBypass(machO, teamID: teamID)
        try cmdChangeOwnerToInstalld(fwkURL, recursively: true)

        return fwkURL
    }

    fileprivate func standardizeLoadCommandDylibToSubstrate(_ assetURL: URL) throws {
        let machO: URL
        if checkIsBundle(assetURL) {
            machO = try locateExecutableInBundle(assetURL)
        } else {
            machO = assetURL
        }

        let dylibs = try loadedDylibsOfMachO(machO)
        for dylib in dylibs {
            if Self.ignoredDylibAndFrameworkNames.firstIndex(where: { dylib.lowercased().hasSuffix("/\($0)") }) != nil {
                try cmdChangeLoadCommandDylib(machO, from: dylib, to: "@executable_path/Frameworks/\(Self.substrateFwkName)/\(Self.substrateName)")
            }
        }
    }

    // MARK: - Load Commands

    func loadCommandNameOfAsset(_ assetURL: URL) throws -> String {
        var name = "@rpath/"

        if checkIsBundle(assetURL) {
            precondition(assetURL.pathExtension == "framework", "Invalid framework: \(assetURL.path)")
            let machO = try locateExecutableInBundle(assetURL)
            name += machO.pathComponents.suffix(2).joined(separator: "/") // @rpath/XXX.framework/XXX
            precondition(name.contains(".framework/"), "Invalid framework name: \(name)")
        } else {
            precondition(assetURL.pathExtension == "dylib", "Invalid dylib: \(assetURL.path)")
            name += assetURL.lastPathComponent
            precondition(name.hasSuffix(".dylib"), "Invalid dylib name: \(name)") // @rpath/XXX.dylib
        }

        return name
    }

    fileprivate func insertLoadCommandOfAsset(_ assetURL: URL, to target: URL) throws {
        let name = try loadCommandNameOfAsset(assetURL)

        try cmdInsertLoadCommandRuntimePath(target, name: "@executable_path/Frameworks")
        try cmdInsertLoadCommandDylib(target, name: name, weak: useWeakReference)
        try standardizeLoadCommandDylib(target, to: name)
    }

    fileprivate func standardizeLoadCommandDylib(_ target: URL, to name: String) throws {
        precondition(name.hasPrefix("@rpath/"), "Invalid dylib name: \(name)")

        let itemName = String(name[name.index(name.startIndex, offsetBy: 7)...])
        let dylibs = try loadedDylibsOfMachO(target)

        for dylib in dylibs {
            if dylib.hasSuffix("/" + itemName) {
                try cmdChangeLoadCommandDylib(target, from: dylib, to: name)
            }
        }
    }

    // MARK: - Path Clone

    fileprivate func copyfiles(_ assetURLs: [URL]) throws {
        let targetURLs = assetURLs.map {
            frameworksDirectoryURL.appendingPathComponent($0.lastPathComponent)
        }

        for (assetURL, targetURL) in zip(assetURLs, targetURLs) {
            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: checkIsDirectory(assetURL))
        }
    }

    fileprivate func batchRemove(_ assetURLs: [URL]) throws {
        try assetURLs.forEach {
            try cmdRemove($0, recursively: checkIsDirectory($0))
        }
    }

    // MARK: - Path Finder

    fileprivate func locateAvailableMachO() throws -> URL? {
        let allMachOs = try frameworkMachOsInBundle(bundleURL)

        DDLogInfo("Mach-O scan: \(allMachOs.count) candidates in \(bundleURL.lastPathComponent)", ddlog: logger)

        var selectedMachO: URL?
        var encryptedCount = 0
        var unreadableCount = 0
        for (index, machO) in allMachOs.enumerated() {
            let fileSize = (try? machO.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)

            do {
                let isProtected = try isProtectedMachO(machO)
                if isProtected {
                    encryptedCount += 1
                    DDLogInfo("  [\(index + 1)/\(allMachOs.count)] ENCRYPTED \(machO.lastPathComponent) (\(sizeStr))", ddlog: logger)
                } else {
                    DDLogInfo("  [\(index + 1)/\(allMachOs.count)] AVAILABLE \(machO.lastPathComponent) (\(sizeStr))", ddlog: logger)
                    if selectedMachO == nil {
                        selectedMachO = machO
                    }
                }
            } catch {
                unreadableCount += 1
                DDLogError("  [\(index + 1)/\(allMachOs.count)] UNREADABLE \(machO.lastPathComponent) (\(sizeStr)): \(error)", ddlog: logger)
            }
        }

        if let selected = selectedMachO {
            DDLogInfo("Selected Mach-O: \(selected.lastPathComponent)", ddlog: logger)
        } else {
            DDLogError(
                "No available Mach-O found: \(encryptedCount) encrypted, \(unreadableCount) unreadable, \(allMachOs.count - encryptedCount - unreadableCount) unavailable",
                ddlog: logger
            )
        }

        return selectedMachO
    }

    fileprivate static func findResource(_ name: String, fileExtension: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent()
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            if FileManager.default.isReadableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            if FileManager.default.isReadableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("Unable to locate resource \(name)")
    }
}

// MARK: - Plug-In Structure

enum PlugInStructureKind: String {
    case dylib
    case framework
    case bundle
    case unsupported

    var localizedName: String {
        switch self {
        case .dylib: NSLocalizedString("Dylib", comment: "")
        case .framework: NSLocalizedString("Framework", comment: "")
        case .bundle: NSLocalizedString("Bundle", comment: "")
        case .unsupported: NSLocalizedString("Unknown", comment: "")
        }
    }
}

extension InjectorV3 {
    // MARK: - Inspection

    func structureKindOfAsset(_ assetURL: URL) -> PlugInStructureKind {
        switch assetURL.pathExtension.lowercased() {
        case "dylib": .dylib
        case "framework": .framework
        case "bundle": .bundle
        default: .unsupported
        }
    }

    func analyzeBundleStructure() -> BundleStructureReport {
        BundleStructureReport(bundleURL: bundleURL, entries: structureEntriesInBundle())
    }

    /// Snapshot of every Mach-O inside the target bundle: architectures, encryption,
    /// loaded dylibs and runtime paths.
    func analyzeBundleStructure() -> BundleStructureReport {
        BundleStructureReport(bundleURL: bundleURL, entries: structureEntriesInBundle())
    }

    // MARK: - Restructure

    /// Relocates a bare dylib into a proper `XXX.framework` bundle and rewrites every
    /// load command that used to point at the bare dylib.
    @discardableResult
    func convertAssetToFramework(_ assetURL: URL) throws -> URL {
        guard structureKindOfAsset(assetURL) == .dylib else {
            throw Error.generic(NSLocalizedString("This plug-in is not a dylib.", comment: ""))
        }

        try checkAssetIsInjected(assetURL)

        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw Error.generic(String(format: NSLocalizedString("Plug-in not found: %@", comment: ""), assetURL.lastPathComponent))
        }

        terminateApp()

        let baseName = assetURL.deletingPathExtension().lastPathComponent
        let frameworkURL = frameworksDirectoryURL
            .appendingPathComponent(baseName, isDirectory: false)
            .appendingPathExtension("framework")
        let frameworkMachOURL = frameworkURL.appendingPathComponent(baseName, isDirectory: false)

        let oldItemName = assetURL.lastPathComponent
        let newLoadCommandName = "@rpath/\(baseName).framework/\(baseName)"

        let references = loadCommandReferences(matching: oldItemName)
        let previousLoadCommands = references.map { ($0.target, $0.name) }

        if FileManager.default.fileExists(atPath: frameworkURL.path) {
            try cmdRemove(frameworkURL, recursively: true)
        }

        do {
            try cmdMakeDirectory(at: frameworkURL)
            try cmdCopy(from: assetURL, to: frameworkMachOURL)
            try installFrameworkInfoPlist(at: frameworkURL, executableName: baseName)
            try markBundlesAsInjected([frameworkURL], privileged: true)

            try rewriteLoadCommands(references, to: newLoadCommandName)
            try cmdRemove(assetURL)

            try applyCoreTrustBypass(frameworkURL)
            for target in uniqueTargets(references.map { $0.target }) {
                try applyCoreTrustBypass(target)
            }
        } catch {
            try? cmdRemove(frameworkURL, recursively: true)
            for (target, name) in previousLoadCommands {
                try? cmdChangeLoadCommandDylib(target, from: newLoadCommandName, to: name)
            }
            throw error
        }

        DDLogInfo("Restructured \(oldItemName) as \(frameworkURL.lastPathComponent)", ddlog: logger)

        return frameworkURL
    }

    /// The opposite of `convertAssetToFramework(_:)`: flattens a framework back into a bare dylib.
    @discardableResult
    func convertAssetToDylib(_ assetURL: URL) throws -> URL {
        guard structureKindOfAsset(assetURL) == .framework else {
            throw Error.generic(NSLocalizedString("This plug-in is not a framework.", comment: ""))
        }

        try checkAssetIsInjected(assetURL)

        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw Error.generic(String(format: NSLocalizedString("Plug-in not found: %@", comment: ""), assetURL.lastPathComponent))
        }

        terminateApp()

        let baseName = assetURL.deletingPathExtension().lastPathComponent
        let frameworkMachOURL = try locateExecutableInBundle(assetURL)
        let dylibURL = frameworksDirectoryURL
            .appendingPathComponent(baseName, isDirectory: false)
            .appendingPathExtension("dylib")

        let oldItemName = "\(baseName).framework/\(baseName)"
        let newLoadCommandName = "@rpath/\(baseName).dylib"

        let references = loadCommandReferences(matching: oldItemName)
        let previousLoadCommands = references.map { ($0.target, $0.name) }

        if FileManager.default.fileExists(atPath: dylibURL.path) {
            try cmdRemove(dylibURL)
        }

        do {
            try cmdCopy(from: frameworkMachOURL, to: dylibURL)

            try rewriteLoadCommands(references, to: newLoadCommandName)
            try cmdRemove(assetURL, recursively: true)

            try applyCoreTrustBypass(dylibURL)
            for target in uniqueTargets(references.map { $0.target }) {
                try applyCoreTrustBypass(target)
            }
        } catch {
            try? cmdRemove(dylibURL)
            for (target, name) in previousLoadCommands {
                try? cmdChangeLoadCommandDylib(target, from: newLoadCommandName, to: name)
            }
            throw error
        }

        DDLogInfo("Restructured \(baseName).framework as \(dylibURL.lastPathComponent)", ddlog: logger)

        return dylibURL
    }

    /// Swaps the contents of an already injected plug-in in place, keeping its load command untouched.
    func replaceAsset(at oldURL: URL, with newURL: URL) throws {
        guard FileManager.default.fileExists(atPath: oldURL.path) else {
            throw Error.generic(String(format: NSLocalizedString("Plug-in not found: %@", comment: ""), oldURL.lastPathComponent))
        }

        terminateApp()

        let newIsDirectory = checkIsDirectory(newURL)
        try cmdRemove(oldURL, recursively: checkIsDirectory(oldURL))
        try cmdCopy(from: newURL, to: oldURL, overwrite: true)
        try cmdChangeOwnerToInstalld(oldURL, recursively: newIsDirectory)
        try applyCoreTrustBypass(oldURL)
    }

    // MARK: - Private Helpers

    /// Every Mach-O whose load commands reference the given item name,
    /// either as a bare item (`Foo.dylib`) or as a nested framework item (`Foo.framework/Foo`).
    fileprivate func loadCommandReferences(matching itemName: String) -> [(target: URL, name: String)] {
        var targets = [executableURL]
        targets.append(contentsOf: machOsInFrameworksDirectory())

        var references = [(target: URL, name: String)]()
        for target in uniqueTargets(targets) {
            guard let dylibs = try? loadedDylibsOfMachO(target) else {
                continue
            }
            for name in dylibs where name == itemName || name.hasSuffix("/" + itemName) {
                references.append((target, name))
            }
        }
        return references
    }

    fileprivate func rewriteLoadCommands(_ references: [(target: URL, name: String)], to newName: String) throws {
        for reference in references {
            try cmdInsertLoadCommandRuntimePath(reference.target, name: "@executable_path/Frameworks")
            try cmdChangeLoadCommandDylib(reference.target, from: reference.name, to: newName)
        }
    }

    fileprivate func uniqueTargets(_ targets: [URL]) -> [URL] {
        var seen = Set<String>()
        var results = [URL]()
        for target in targets where !seen.contains(target.path) {
            seen.insert(target.path)
            results.append(target)
        }
        return results
    }

    /// Restructuring only makes sense for assets that already live inside the target bundle.
    fileprivate func checkAssetIsInjected(_ assetURL: URL) throws {
        let prefix = frameworksDirectoryURL.path + "/"
        guard assetURL.path.hasPrefix(prefix),
              FileManager.default.fileExists(atPath: assetURL.path)
        else {
            throw Error.generic(NSLocalizedString("Only injected plug-ins can be restructured.", comment: ""))
        }
    }

    fileprivate func installFrameworkInfoPlist(at frameworkURL: URL, executableName: String) throws {
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.trollfools.injected.\(executableName.lowercased())",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": executableName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "14.0",
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let temporaryPlistURL = temporaryDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-Info.plist")
        try data.write(to: temporaryPlistURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: temporaryPlistURL)
        }

        try cmdCopy(
            from: temporaryPlistURL,
            to: frameworkURL.appendingPathComponent("Info.plist"),
            overwrite: true
        )
    }
}
