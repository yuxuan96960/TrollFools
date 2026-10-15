//
//  PlugInCell.swift
//  TrollFools
//
//  Created by 82Flex on 2024/10/30.
//

import QuickLook
import SwiftUI

private let gDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

struct PlugInCell: View {
    @EnvironmentObject var ejectList: EjectListModel
    @Environment(\.verticalSizeClass) var verticalSizeClass

    @Binding var quickLookExport: URL?
    @State var isEnabled: Bool = false

    let plugIn: InjectedPlugIn

    var onRenameRequest: ((InjectedPlugIn) -> Void)?
    var onReplaceRequest: ((InjectedPlugIn) -> Void)?
    var onFrameworkRequest: ((InjectedPlugIn) -> Void)?

    init(
        _ plugIn: InjectedPlugIn,
        quickLookExport: Binding<URL?>,
        onRenameRequest: ((InjectedPlugIn) -> Void)? = nil,
        onReplaceRequest: ((InjectedPlugIn) -> Void)? = nil,
        onFrameworkRequest: ((InjectedPlugIn) -> Void)? = nil
    ) {
        self.plugIn = plugIn
        _quickLookExport = quickLookExport
        self.onRenameRequest = onRenameRequest
        self.onReplaceRequest = onReplaceRequest
        self.onFrameworkRequest = onFrameworkRequest
    }

    @available(iOS 15, *)
    var highlightedName: AttributedString {
        let name = plugIn.displayName
        var attributedString = AttributedString(name)
        if let range = attributedString.range(of: ejectList.filter.searchKeyword, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributedString[range].foregroundColor = .accentColor
        }
        return attributedString
    }

    var iconName: String {
        let pathExt = plugIn.url.pathExtension.lowercased()
        if pathExt == "bundle" {
            return "archivebox"
        }
        if pathExt == "dylib" {
            return "bandage"
        }
        if pathExt == "framework" {
            return "shippingbox"
        }
        return "puzzlepiece"
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: 12) {
                if verticalSizeClass == .compact {
                    Image(systemName: iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading) {
                    if #available(iOS 15, *) {
                        Text(highlightedName)
                            .font(.headline)
                            .lineLimit(2)
                    } else {
                        Text(plugIn.displayName)
                            .font(.headline)
                            .lineLimit(2)
                    }

                    Text(gDateFormatter.string(from: plugIn.createdAt))
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
        .onAppear {
            isEnabled = plugIn.isEnabled
        }
        .onChange(of: isEnabled) { value in
            ejectList.togglePlugIn(plugIn, isEnabled: value)
        }
        .contextMenu {
            Button {
                onRenameRequest?(plugIn)
            } label: {
                Label(NSLocalizedString("Rename", comment: ""), systemImage: "pencil")
            }

            Button {
                onReplaceRequest?(plugIn)
            } label: {
                Label(NSLocalizedString("Replace", comment: ""), systemImage: "arrow.triangle.2.circlepath")
            }

            if #available(iOS 16.4, *) {
                ShareLink(item: plugIn.url) {
                    Label(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    exportPlugIn()
                } label: {
                    Label(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up")
                }
            }

            Button {
                openInFilza()
            } label: {
                if isFilzaInstalled {
                    Label(NSLocalizedString("Show in Filza", comment: ""), systemImage: "scope")
                } else {
                    Label(NSLocalizedString("Filza (URL Scheme) Not Installed", comment: ""), systemImage: "xmark.octagon")
                }
            }
            .disabled(!isFilzaInstalled)

            Button {
                onFrameworkRequest?(plugIn)
            } label: {
                Label(NSLocalizedString("Framework", comment: ""), systemImage: "shippingbox")
            }
        }
    }

    private func exportPlugIn() {
        quickLookExport = plugIn.url
    }

    var isFilzaInstalled: Bool { ejectList.app.appList?.isFilzaInstalled ?? false }

    private func openInFilza() {
        ejectList.app.appList?.openInFilza(plugIn.url)
    }
}

// MARK: - Rename

struct PlugInRenameView: View {
    @EnvironmentObject var ejectList: EjectListModel
    @Environment(\.presentationMode) var presentationMode

    let plugIn: InjectedPlugIn

    @State var text: String = ""

    init(plugIn: InjectedPlugIn) {
        self.plugIn = plugIn
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(plugIn.url.lastPathComponent, text: $text)
                } header: {
                    Text(NSLocalizedString("Display Name", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Leave it empty to restore the original file name.", comment: ""))
                        .font(.footnote)
                }
            }
            .navigationTitle(NSLocalizedString("Rename", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text(NSLocalizedString("Cancel", comment: ""))
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        ejectList.setAlias(text, for: plugIn)
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text(NSLocalizedString("Save", comment: ""))
                    }
                }
            }
        }
        .onAppear {
            text = plugIn.alias ?? ""
        }
    }
}

// MARK: - Framework

struct PlugInFrameworkView: View {
    @Environment(\.presentationMode) var presentationMode

    let app: App
    let plugIn: InjectedPlugIn

    var onCompleted: ((URL) -> Void)?

    @State var currentURL: URL
    @State var entries: [MachOStructureEntry] = []
    @State var isProcessing = false
    @State var statusMessage: String?
    @State var errorMessage: String?

    init(app: App, plugIn: InjectedPlugIn, onCompleted: ((URL) -> Void)? = nil) {
        self.app = app
        self.plugIn = plugIn
        self.onCompleted = onCompleted
        _currentURL = State(initialValue: plugIn.url)
    }

    var structureKind: PlugInStructureKind {
        PlugInStructureKind(rawValue: currentURL.pathExtension.lowercased()) ?? .unsupported
    }

    var structureIconName: String {
        switch structureKind {
        case .dylib: "bandage"
        case .framework: "shippingbox"
        case .bundle: "archivebox"
        case .unsupported: "puzzlepiece"
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: structureIconName)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentURL.lastPathComponent)
                                .font(.headline)
                                .lineLimit(2)

                            Text(String(format: NSLocalizedString("Current structure: %@", comment: ""), structureKind.localizedName))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Plug-In", comment: ""))
                }

                Section {
                    if entries.isEmpty {
                        Text(NSLocalizedString("No Mach-O found.", comment: ""))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            structureRow(entry)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("App Structure", comment: ""))
                }

                Section {
                    if structureKind == .dylib {
                        Button {
                            restructure(asFramework: true)
                        } label: {
                            Label(NSLocalizedString("Convert to Framework Structure", comment: ""), systemImage: "shippingbox")
                        }
                        .disabled(isProcessing)
                    } else if structureKind == .framework {
                        Button {
                            restructure(asFramework: false)
                        } label: {
                            Label(NSLocalizedString("Convert to Dylib Structure", comment: ""), systemImage: "bandage")
                        }
                        .disabled(isProcessing)
                    }

                    if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(NSLocalizedString("Processing…", comment: ""))
                                .foregroundColor(.secondary)
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .foregroundColor(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(Color(.systemRed))
                    }
                } header: {
                    Text(NSLocalizedString("Restructure", comment: ""))
                } footer: {
                    Text(NSLocalizedString("The plug-in will be relocated into Frameworks/ and every load command pointing at it will be rewritten.", comment: ""))
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("Framework", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text(NSLocalizedString("Done", comment: ""))
                    }
                }
            }
        }
        .onAppear {
            reloadStructure()
        }
    }

    @ViewBuilder
    private func structureRow(_ entry: MachOStructureEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.relativePath)
                    .font(.subheadline)
                    .lineLimit(2)

                if entry.isMainExecutable {
                    Text(NSLocalizedString("Main", comment: ""))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 8) {
                Text(entry.architecturesDescription)
                Text(entry.fileSizeDescription)
                if entry.isEncrypted {
                    Text(NSLocalizedString("Encrypted", comment: ""))
                        .foregroundColor(Color(.systemOrange))
                }
                if entry.hasBackup {
                    Text(NSLocalizedString("Patched", comment: ""))
                        .foregroundColor(.accentColor)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if !entry.loadedDylibs.isEmpty {
                Text(entry.loadedDylibs.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(6)
            }
        }
        .padding(.vertical, 2)
    }

    private func makeInjector() throws -> InjectorV3 {
        let injector = try InjectorV3(app.url)
        if injector.appID.isEmpty {
            injector.appID = app.bid
        }
        if injector.teamID.isEmpty {
            injector.teamID = app.teamID
        }
        return injector
    }

    private func reloadStructure() {
        guard let injector = try? makeInjector() else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let newEntries = injector.structureEntriesInBundle()
            DispatchQueue.main.async {
                self.entries = newEntries
            }
        }
    }

    private func restructure(asFramework: Bool) {
        guard !isProcessing else {
            return
        }

        guard let injector = try? makeInjector() else {
            errorMessage = NSLocalizedString("Unable to load the target application.", comment: "")
            return
        }

        isProcessing = true
        errorMessage = nil
        statusMessage = nil

        let targetURL = currentURL

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newURL = asFramework
                    ? try injector.convertAssetToFramework(targetURL)
                    : try injector.convertAssetToDylib(targetURL)

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.currentURL = newURL
                    self.statusMessage = NSLocalizedString("Done.", comment: "")
                    self.reloadStructure()
                    self.onCompleted?(newURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
