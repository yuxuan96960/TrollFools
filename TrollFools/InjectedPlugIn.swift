//
//  InjectedPlugIn.swift
//  TrollFools
//
//  Created by 82Flex on 2024/10/30.
//

import Foundation

struct InjectedPlugIn: Equatable, Identifiable, Hashable {
    let id: String
    let url: URL
    let createdAt: Date
    let isEnabled: Bool
    let alias: String?

    var displayName: String {
        alias ?? url.lastPathComponent
    }

    init(url: URL, isEnabled: Bool, alias: String? = nil) {
        self.id = url.absoluteString
        self.url = url
        self.createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        self.isEnabled = isEnabled
        self.alias = alias
    }
}
