//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Foundation
import PackageModel
import PackageRegistry
import TSCBasic
import Workspace

public struct SwiftPackageRegistryTool: ParsableCommand {
    public static var configuration = CommandConfiguration(
        commandName: "package-registry",
        _superCommandName: "swift",
        abstract: "Interact with package registry and manage related configuration",
        discussion: "SEE ALSO: swift package",
        version: SwiftVersion.current.completeDisplayString,
        subcommands: [
            Set.self,
            Unset.self,
            Login.self,
            Logout.self,
            Publish.self,
        ],
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)]
    )

    @OptionGroup()
    var globalOptions: GlobalOptions

    public init() {}

    struct Set: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a custom registry"
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Flag(help: "Apply settings to all projects for this user")
        var global: Bool = false

        @Option(help: "Associate the registry with a given scope")
        var scope: String?

        @Argument(help: "The registry URL")
        var url: URL

        var registryURL: URL {
            self.url
        }

        func run(_ swiftTool: SwiftTool) throws {
            try self.registryURL.validateRegistryURL()

            let scope = try scope.map(PackageIdentity.Scope.init(validating:))

            let set: (inout RegistryConfiguration) throws -> Void = { configuration in
                if let scope = scope {
                    configuration.scopedRegistries[scope] = .init(url: self.registryURL)
                } else {
                    configuration.defaultRegistry = .init(url: self.registryURL)
                }
            }

            let configuration = try getRegistriesConfig(swiftTool)
            if self.global {
                try configuration.updateShared(with: set)
            } else {
                try configuration.updateLocal(with: set)
            }
        }
    }

    struct Unset: SwiftCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a configured registry"
        )

        @OptionGroup(visibility: .hidden)
        var globalOptions: GlobalOptions

        @Flag(help: "Apply settings to all projects for this user")
        var global: Bool = false

        @Option(help: "Associate the registry with a given scope")
        var scope: String?

        func run(_ swiftTool: SwiftTool) throws {
            let scope = try scope.map(PackageIdentity.Scope.init(validating:))

            let unset: (inout RegistryConfiguration) throws -> Void = { configuration in
                if let scope = scope {
                    guard let _ = configuration.scopedRegistries[scope] else {
                        throw ConfigurationError.missingScope(scope)
                    }
                    configuration.scopedRegistries.removeValue(forKey: scope)
                } else {
                    guard let _ = configuration.defaultRegistry else {
                        throw ConfigurationError.missingScope()
                    }
                    configuration.defaultRegistry = nil
                }
            }

            let configuration = try getRegistriesConfig(swiftTool)
            if self.global {
                try configuration.updateShared(with: unset)
            } else {
                try configuration.updateLocal(with: unset)
            }
        }
    }

    // common utility

    enum ConfigurationError: Swift.Error {
        case missingScope(PackageIdentity.Scope? = nil)
    }

    enum ValidationError: Swift.Error {
        case invalidURL(URL)
        case invalidPackageIdentity(PackageIdentity)
        case unknownRegistry
        case unknownCredentialStore
    }

    static func getRegistriesConfig(_ swiftTool: SwiftTool) throws -> Workspace.Configuration.Registries {
        let workspace = try swiftTool.getActiveWorkspace()
        return try .init(
            fileSystem: swiftTool.fileSystem,
            localRegistriesFile: workspace.location.localRegistriesConfigurationFile,
            sharedRegistriesFile: workspace.location.sharedRegistriesConfigurationFile
        )
    }
}

extension URL {
    func validateRegistryURL() throws {
        guard self.scheme == "https" else {
            throw SwiftPackageRegistryTool.ValidationError.invalidURL(self)
        }
    }
}

extension SwiftPackageRegistryTool.ConfigurationError: CustomStringConvertible {
    var description: String {
        switch self {
        case .missingScope(let scope?):
            return "no existing entry for scope: \(scope)"
        case .missingScope:
            return "no existing entry for default scope"
        }
    }
}

extension SwiftPackageRegistryTool.ValidationError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidURL(let url):
            return "invalid URL: \(url)"
        case .invalidPackageIdentity(let identity):
            return "invalid package identity: \(identity)"
        case .unknownRegistry:
            return "unknown registry, is one configured?"
        case .unknownCredentialStore:
            return "No credential store available"
        }
    }
}
