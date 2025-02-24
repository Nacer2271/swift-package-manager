//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Commands
import CrossCompilationDestinationsTool
import PackageCollectionsTool
import PackageRegistryTool
import TSCBasic

let firstArg = CommandLine.arguments[0]
let execName = (try? AbsolutePath(validating: firstArg).basenameWithoutExt) ??
    (try? RelativePath(validating: firstArg).basenameWithoutExt)

@main
struct SwiftPM {
    static func main() {
        switch execName {
        case "swift-package":
            SwiftPackageTool.main()
        case "swift-build":
            SwiftBuildTool.main()
        case "swift-experimental-destination":
            SwiftDestinationTool.main()
        case "swift-test":
            SwiftTestTool.main()
        case "swift-run":
            SwiftRunTool.main()
        case "swift-package-collection":
            SwiftPackageCollectionsTool.main()
        case "swift-package-registry":
            SwiftPackageRegistryTool.main()
        default:
            fatalError("swift-package-manager launched with unexpected name: \(execName ?? "(unknown)")")
        }
    }
}
