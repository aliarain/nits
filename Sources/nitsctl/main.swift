import Foundation
import NitsCore

let status = await NitsCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
