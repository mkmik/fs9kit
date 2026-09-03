import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let usage = """
fs9p — mount and inspect 9P filesystems on macOS without a kernel extension

usage: fs9p <command> [options]

  mount <address> <mountpoint>   mount a 9P server at a path
  umount <mountpoint>            unmount it again
  serve <directory>              export a local directory over 9P
  ls <address> [path]            list a directory
  cat <address> <path>           write a file to stdout
  stat <address> [path]          show one file's attributes and the volume's
  tree <address> [path]          print the tree
  doctor                         report which mount backends this machine can use

addresses take the Plan 9 dial-string forms and a few shorthands:

  tcp!host!564    unix!/tmp/ns/9p    host:564    host    /tmp/ns/9p

common options:

  --uname=NAME     user name sent at attach (default: $USER)
  --aname=TREE     file tree to attach to (default: empty)
  --uid=N --gid=N  numeric ids to present, and to report for files
  --msize=BYTES    largest message to negotiate (default: 512 KiB)
  --version=V      pin the dialect: 9P2000, 9P2000.u or 9P2000.L
  --timeout=SECS   connect and handshake timeout

run `fs9p <command> --help` for a command's own options.
"""

func run() async -> Int32 {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else {
        print(usage)
        return 2
    }
    argv.removeFirst()
    let arguments = Arguments(argv)

    do {
        switch command {
        case "ls": try await Inspect.ls(arguments)
        case "cat": try await Inspect.cat(arguments)
        case "stat": try await Inspect.stat(arguments)
        case "tree": try await Inspect.tree(arguments)
        case "serve": try Serve.run(arguments)
        case "mount": try await Mount.run(arguments)
        case "umount", "unmount": try Mount.unmount(arguments)
        case "doctor": Doctor.run(arguments)
        case "help", "--help", "-h": print(usage)
        case "version", "--version":
            print("fs9p \(fs9pVersion)")
        default:
            FileHandle.standardError.write(Data("unknown command '\(command)'\n\n".utf8))
            print(usage)
            return 2
        }
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("fs9p: \(error.description)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("fs9p: \(error)\n".utf8))
        return 1
    }
    return 0
}

let fs9pVersion = "0.1.0"

exit(await run())
