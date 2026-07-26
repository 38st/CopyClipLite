import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: atomic_swap.swift <first-path> <second-path>\n".utf8))
    exit(2)
}

let firstPath = CommandLine.arguments[1]
let secondPath = CommandLine.arguments[2]
let result = renameatx_np(
    AT_FDCWD,
    firstPath,
    AT_FDCWD,
    secondPath,
    UInt32(RENAME_SWAP)
)

guard result == 0 else {
    let message = String(cString: strerror(errno))
    FileHandle.standardError.write(
        Data("Unable to atomically swap \(firstPath) and \(secondPath): \(message)\n".utf8)
    )
    exit(1)
}
