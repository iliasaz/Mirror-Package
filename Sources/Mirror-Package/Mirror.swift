import ArgumentParser
import Foundation
import SystemPackage

@main
struct Mirror: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Utility for creating a local mirror of a Swift project's package dependencies.",
        version: "1.1.1"
    )

    @Option(name: [.long, .short], help: "Directory which will hold the local mirrors")
    var mirrorPath: String

    @Option(name: [.long, .short], help: "Path to the git executable")
    var gitPath: String = "/usr/bin/git"

    @Option(name: [.long, .short], help: "Path to the swift executable")
    var swiftPath: String = "/usr/bin/swift"
  
    @Flag(name: [.long, .short], help: "Use exact revisions only")
    var withSHA: Bool = true

    @Flag(name: [.long, .short], help: "Update all local mirrors in the mirror directory")
    var update: Bool = false
  
    @Option(name: [.long, .short], help: "Directory which will hold the local mirrors in a docker container")
    var dockerMirrorPath: String = "/app/external-deps/checkouts"

    func run() throws {
        if update {
            try updateMirrors()
        } else {
            try configureMirrorsForProject()
        }
    }

    func updateMirrors() throws {
        let currentDir = FileManager.default.currentDirectoryPath
        for fileName in try FileManager.default.contentsOfDirectory(atPath: mirrorPath) {
            var subDir = FilePath(mirrorPath)
            subDir.append(fileName)
            FileManager.default.changeCurrentDirectoryPath(subDir.string)
            do {
                var task = Process()
                print("Updating \(fileName)")
                task.executableURL = URL(fileURLWithPath: gitPath)
                task.arguments = ["restore", ":/"]
                try task.run()
                task.waitUntilExit()

                task = Process()
                task.executableURL = URL(fileURLWithPath: gitPath)
                task.arguments = ["pull", "--rebase"]
                try task.run()
                task.waitUntilExit()
            } catch {
                print("Error updating mirror \(fileName)")
            }
        }
        // restore current directory
        FileManager.default.changeCurrentDirectoryPath(currentDir)
    }

    func configureMirrorsForProject() throws {
        // look for Package.resolved in the current directory
        var path = FilePath(FileManager.default.currentDirectoryPath)
        path.append("Package.resolved")
        let package = try String(contentsOfFile: path.string)
        guard let packageData = package.data(using: .utf8) else { throw ReadError.unreadable }
        let decodedPackage = try JSONDecoder().decode(DecodedManifest.self, from: packageData)
        var dependencies: [(url: String, revision: String?)] = []
        for pin in decodedPackage.pins {
            switch pin.kind {
            case "remoteSourceControl":
                print("Found a dependency: \(pin.identity)")
                dependencies.append((url: pin.location, revision: pin.revision))
            case "localSourceControl":
                print("Found a dependency that's already local: \(pin.identity)")
            default:
                print("Found a dependency I don't know how to mirror: \(pin.identity), kind: \(pin.kind)")
            }
        }
        // Now, we want to go to the mirror root and do a git clone of each dependency
        // unless, of course, it's already been cloned.
        let projectDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(mirrorPath)
        var mirrors: [String: String] = [:]
        for dep in dependencies {
            do {
                var directory = FilePath(mirrorPath)
                let subDir = try clone(source: dep.url, revision: dep.revision)
                directory.append(subDir)
                mirrors[dep.url] = directory.string
            } catch {
                print("Error cloning dependency '\(dep.url)': \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        // Finally, now that we've got all the dependencies cloned into our mirror directory,
        // we need to go back to the project directory and tell SPM that we're mirroring.
        FileManager.default.changeCurrentDirectoryPath(projectDir)
        for dep in dependencies {
            if let mirror = mirrors[dep.url] {
                do {
                    try registerMirror(source: dep.url, mirror: mirror)
                    if !dep.url.hasSuffix(".git") {
                        try registerMirror(source: dep.url.appending(".git"), mirror: mirror)
                    }
                } catch {
                    print("Error registering mirror for \(dep.url)")
                }
            }
        }

        // Generate mirror config files
        try writeMirrorsConfig(mirrors: mirrors)
        try writeDockerMirrorsConfig(mirrors: mirrors)
    }

    func registerMirror(source: String, mirror: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: swiftPath)
        task.arguments = ["package", "config", "set-mirror",
                          "--original", source,
                          "--mirror", mirror]
        try task.run()
        task.waitUntilExit()
    }

    @discardableResult
    func runGit(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gitPath)
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func clone(source: String, revision: String?) throws -> String {
        guard let subDir = source.split(separator: "/").last else {
            print("weird source repo URL: \(source)")
            return ""
        }
        var returnSubDir = String(subDir)
        if subDir.hasSuffix(".git") {
            returnSubDir = String(subDir.dropLast(4))
        }

        // If the subdirectory doesn't exist already, then we clone the dependency
        var directory = FilePath(FileManager.default.currentDirectoryPath)
        directory.append(returnSubDir)
        if FileManager.default.fileExists(atPath: directory.string) {
            print("Already mirroring \(source)")
            return returnSubDir
        }

        if withSHA, let revision = revision {
            print("Shallow cloning \(source) at \(revision)")
            try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
            try runGit(["-C", directory.string, "init"])
            try runGit(["-C", directory.string, "remote", "add", "origin", source])
            try runGit(["-C", directory.string, "fetch", "--depth", "1", "origin", revision])
            try runGit(["-C", directory.string, "checkout", "--detach", revision])
            try runGit(["-C", directory.string, "repack", "-a", "-d"])
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: gitPath)
            task.arguments = ["clone", source]
            try task.run()
            task.waitUntilExit()
        }
        return returnSubDir
    }

    func writeMirrorsConfig(mirrors: [String: String]) throws {
        var entries: [[String: String]] = []
        for (original, localPath) in mirrors {
            entries.append(["original": original, "mirror": localPath])
            if !original.hasSuffix(".git") {
                entries.append(["original": original.appending(".git"), "mirror": localPath])
            }
        }
        let config: [String: Any] = [
            "object": entries,
            "version": 1
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let configDir = FilePath(FileManager.default.currentDirectoryPath)
            .appending(".swiftpm")
            .appending("configuration")
        try FileManager.default.createDirectory(atPath: configDir.string, withIntermediateDirectories: true)
        let outputPath = configDir.appending("mirrors.json")
        try jsonData.write(to: URL(fileURLWithPath: outputPath.string))
        print("Wrote mirrors config to \(outputPath.string)")
    }

    func writeDockerMirrorsConfig(mirrors: [String: String]) throws {
        var entries: [[String: String]] = []
        for (original, localPath) in mirrors {
            // Derive the subdirectory name from the local mirror path
            let subDir = FilePath(localPath).lastComponent?.string ?? ""
            var dockerPath = FilePath(dockerMirrorPath)
            dockerPath.append(subDir)
            entries.append(["original": original, "mirror": dockerPath.string])
            // Also add .git variant if the original doesn't end with .git
            if !original.hasSuffix(".git") {
                entries.append(["original": original.appending(".git"), "mirror": dockerPath.string])
            }
        }
        let config: [String: Any] = [
            "object": entries,
            "version": 1
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let outputPath = FilePath(FileManager.default.currentDirectoryPath).appending("docker-mirrors.json")
        try jsonData.write(to: URL(fileURLWithPath: outputPath.string))
        print("Wrote docker mirrors config to \(outputPath.string)")
    }
}
