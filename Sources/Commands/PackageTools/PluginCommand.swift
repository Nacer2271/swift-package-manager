//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import Dispatch
import PackageGraph
import PackageModel
import TSCBasic

struct PluginCommand: SwiftCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Invoke a command plugin or perform other actions on command plugins"
    )

    @OptionGroup(visibility: .hidden)
    var globalOptions: GlobalOptions

    @Flag(name: .customLong("list"),
          help: "List the available command plugins")
    var listCommands: Bool = false

    struct PluginOptions: ParsableArguments {
        @Flag(name: .customLong("allow-writing-to-package-directory"),
              help: "Allow the plugin to write to the package directory")
        var allowWritingToPackageDirectory: Bool = false

        @Option(name: .customLong("allow-writing-to-directory"),
                help: "Allow the plugin to write to an additional directory")
        var additionalAllowedWritableDirectories: [String] = []

        enum NetworkPermission: String, EnumerableFlag, ExpressibleByArgument {
            case none
            case local
            case all
            case docker
            case unixDomainSocket
        }

        @Option(name: .customLong("allow-network-connections"))
        var allowNetworkConnections: NetworkPermission = .none
    }

    @OptionGroup()
    var pluginOptions: PluginOptions

    @Argument(help: "Verb of the command plugin to invoke")
    var command: String = ""

    @Argument(parsing: .unconditionalRemaining,
              help: "Arguments to pass to the command plugin")
    var arguments: [String] = []

    func run(_ swiftTool: SwiftTool) throws {
        // Check for a missing plugin command verb.
        if command == "" && !listCommands {
            throw ValidationError("Missing expected plugin command")
        }

        // Load the workspace and resolve the package graph.
        let packageGraph = try swiftTool.loadPackageGraph()

        // List the available plugins, if asked to.
        if listCommands {
            let allPlugins = PluginCommand.availableCommandPlugins(in: packageGraph)
            for plugin in allPlugins.sorted(by: { $0.name < $1.name }) {
                guard case .command(let intent, _) = plugin.capability else { return }
                var line = "‘\(intent.invocationVerb)’ (plugin ‘\(plugin.name)’"
                if let package = packageGraph.packages.first(where: { $0.targets.contains(where: { $0.name == plugin.name }) }) {
                    line +=  " in package ‘\(package.manifest.displayName)’"
                }
                line += ")"
                print(line)
            }
            return
        }

        swiftTool.observabilityScope.emit(info: "Finding plugin for command ‘\(command)’")
        let matchingPlugins = PluginCommand.findPlugins(matching: command, in: packageGraph)

        // Complain if we didn't find exactly one.
        if matchingPlugins.isEmpty {
            throw ValidationError("No command plugins found for ‘\(command)’")
        }
        else if matchingPlugins.count > 1 {
            throw ValidationError("\(matchingPlugins.count) plugins found for ‘\(command)’")
        }

        // At this point we know we found exactly one command plugin, so we run it. In SwiftPM CLI, we have only one root package.
        try PluginCommand.run(
            plugin: matchingPlugins[0],
            package: packageGraph.rootPackages[0],
            packageGraph: packageGraph,
            options: pluginOptions,
            arguments: arguments,
            swiftTool: swiftTool)
    }

    static func run(
        plugin: PluginTarget,
        package: ResolvedPackage,
        packageGraph: PackageGraph,
        options: PluginOptions,
        arguments: [String],
        swiftTool: SwiftTool
    ) throws {
        swiftTool.observabilityScope.emit(info: "Running command plugin \(plugin) on package \(package) with options \(options) and arguments \(arguments)")

        // The `plugins` directory is inside the workspace's main data directory, and contains all temporary files related to this plugin in the workspace.
        let pluginsDir = try swiftTool.getActiveWorkspace().location.pluginWorkingDirectory.appending(component: plugin.name)

        // The `cache` directory is in the plugin’s directory and is where the plugin script runner caches compiled plugin binaries and any other derived information for this plugin.
        let pluginScriptRunner = try swiftTool.getPluginScriptRunner(
            customPluginsDir: pluginsDir
        )

        // The `outputs` directory contains subdirectories for each combination of package and command plugin. Each usage of a plugin has an output directory that is writable by the plugin, where it can write additional files, and to which it can configure tools to write their outputs, etc.
        let outputDir = pluginsDir.appending(component: "outputs")

        var allowNetworkConnections = [SandboxNetworkPermission.init(options.allowNetworkConnections)]
        // Determine the set of directories under which plugins are allowed to write. We always include the output directory.
        var writableDirectories = [outputDir]
        if options.allowWritingToPackageDirectory {
            writableDirectories.append(package.path)
        }

        // If the plugin requires permissions, we ask the user for approval.
        if case .command(_, let permissions) = plugin.capability {
            try permissions.forEach {
                let permissionString: String
                let reasonString: String
                let remedyOption: String

                switch $0 {
                case .writeToPackageDirectory(let reason):
                    guard !options.allowWritingToPackageDirectory else { return } // permission already granted
                    permissionString = "write to the package directory"
                    reasonString = reason
                    remedyOption = "--allow-writing-to-package-directory"
                case .allowNetworkConnections(let scope, let reason):
                    guard scope != .none else { return } // no need to prompt
                    guard options.allowNetworkConnections != .init(scope) else { return } // permission already granted

                    switch scope {
                    case .all, .local:
                        let portsString = scope.ports.isEmpty ? "on all ports" : "on ports: \(scope.ports.map { "\($0)" }.joined(separator: ", "))"
                        permissionString = "allow \(scope.label) network connections \(portsString)"
                    case .docker, .unixDomainSocket:
                        permissionString = "allow \(scope.label) connections"
                    case .none:
                        permissionString = "" // should not be reached
                    }

                    reasonString = reason
                    remedyOption = "--allow-network-connections \(PluginCommand.PluginOptions.NetworkPermission.init(scope).defaultValueDescription)"
                }

                let problem = "Plugin ‘\(plugin.name)’ wants permission to \(permissionString)."
                let reason = "Stated reason: “\(reasonString)”."
                if swiftTool.outputStream.isTTY {
                    // We can ask the user directly, so we do so.
                    let query = "Allow this plugin to \(permissionString)?"
                    swiftTool.outputStream.write("\(problem)\n\(reason)\n\(query) (yes/no) ".utf8)
                    swiftTool.outputStream.flush()
                    let answer = readLine(strippingNewline: true)
                    // Throw an error if we didn't get permission.
                    if answer?.lowercased() != "yes" {
                        throw StringError("Plugin was denied permission to \(permissionString).")
                    }
                } else {
                    // We can't ask the user, so emit an error suggesting passing the flag.
                    let remedy = "Use `\(remedyOption)` to allow this."
                    throw StringError([problem, reason, remedy].joined(separator: "\n"))
                }

                switch $0 {
                case .writeToPackageDirectory:
                    // Otherwise append the directory to the list of allowed ones.
                    writableDirectories.append(package.path)
                case .allowNetworkConnections(let scope, _):
                    allowNetworkConnections.append(.init(scope))
                    break
                }
            }
        }

        for pathString in options.additionalAllowedWritableDirectories {
            writableDirectories.append(try AbsolutePath(validating: pathString, relativeTo: swiftTool.originalWorkingDirectory))
        }

        // Make sure that the package path is read-only unless it's covered by any of the explicitly writable directories.
        let readOnlyDirectories = writableDirectories.contains{ package.path.isDescendantOfOrEqual(to: $0) } ? [] : [package.path]

        // Use the directory containing the compiler as an additional search directory, and add the $PATH.
        let toolSearchDirs = [try swiftTool.getDestinationToolchain().swiftCompilerPath.parentDirectory]
            + getEnvSearchPaths(pathString: ProcessEnv.path, currentWorkingDirectory: .none)

        // Build or bring up-to-date any executable host-side tools on which this plugin depends. Add them and any binary dependencies to the tool-names-to-path map.
        let buildSystem = try swiftTool.createBuildSystem(explicitBuildSystem: .native, cacheBuildManifest: false)
        let accessibleTools = try plugin.processAccessibleTools(packageGraph: packageGraph, fileSystem: swiftTool.fileSystem, environment: try swiftTool.buildParameters().buildEnvironment, for: try pluginScriptRunner.hostTriple) { name, path in
            // Build the product referenced by the tool, and add the executable to the tool map. Product dependencies are not supported within a package, so if the tool happens to be from the same package, we instead find the executable that corresponds to the product. There is always one, because of autogeneration of implicit executables with the same name as the target if there isn't an explicit one.
            try buildSystem.build(subset: .product(name))
            if let builtTool = try buildSystem.buildPlan.buildProducts.first(where: { $0.product.name == name}) {
                return builtTool.binaryPath
            } else {
                return nil
            }
        }

        // Set up a delegate to handle callbacks from the command plugin.
        let pluginDelegate = PluginDelegate(swiftTool: swiftTool, plugin: plugin)
        let delegateQueue = DispatchQueue(label: "plugin-invocation")

        // Run the command plugin.
        let buildEnvironment = try swiftTool.buildParameters().buildEnvironment
        let _ = try tsc_await { plugin.invoke(
            action: .performCommand(package: package, arguments: arguments),
            buildEnvironment: buildEnvironment,
            scriptRunner: pluginScriptRunner,
            workingDirectory: swiftTool.originalWorkingDirectory,
            outputDirectory: outputDir,
            toolSearchDirectories: toolSearchDirs,
            accessibleTools: accessibleTools,
            writableDirectories: writableDirectories,
            readOnlyDirectories: readOnlyDirectories,
            allowNetworkConnections: allowNetworkConnections,
            pkgConfigDirectories: swiftTool.options.locations.pkgConfigDirectories,
            fileSystem: swiftTool.fileSystem,
            observabilityScope: swiftTool.observabilityScope,
            callbackQueue: delegateQueue,
            delegate: pluginDelegate,
            completion: $0) }

        // TODO: We should also emit a final line of output regarding the result.
    }

    static func availableCommandPlugins(in graph: PackageGraph) -> [PluginTarget] {
        return graph.allTargets.compactMap{ $0.underlyingTarget as? PluginTarget }
    }

    static func findPlugins(matching verb: String, in graph: PackageGraph) -> [PluginTarget] {
        // Find and return the command plugins that match the command.
        return Self.availableCommandPlugins(in: graph).filter {
            // Filter out any non-command plugins and any whose verb is different.
            guard case .command(let intent, _) = $0.capability else { return false }
            return verb == intent.invocationVerb
        }
    }
}

extension PluginCommandIntent {
    var invocationVerb: String {
        switch self {
        case .documentationGeneration:
            return "generate-documentation"
        case .sourceCodeFormatting:
            return "format-source-code"
        case .custom(let verb, _):
            return verb
        }
    }
}

extension SandboxNetworkPermission {
    init(_ scope: PluginNetworkPermissionScope) {
        switch scope {
        case .none: self = .none
        case .local(let ports): self = .local(ports: ports)
        case .all(let ports): self = .all(ports: ports)
        case .docker: self = .docker
        case .unixDomainSocket: self = .unixDomainSocket
        }
    }
}

extension PluginCommand.PluginOptions.NetworkPermission {
    fileprivate init(_ scope: PluginNetworkPermissionScope) {
        switch scope {
        case .unixDomainSocket: self = .unixDomainSocket
        case .docker: self = .docker
        case .none: self = .none
        case .all: self = .all
        case .local: self = .local
        }
    }
}

extension SandboxNetworkPermission {
    init(_ permission: PluginCommand.PluginOptions.NetworkPermission) {
        switch permission {
        case .none: self = .none
        case .local: self = .local(ports: [])
        case .all: self = .all(ports: [])
        case .docker: self = .docker
        case .unixDomainSocket: self = .unixDomainSocket
        }
    }
}
