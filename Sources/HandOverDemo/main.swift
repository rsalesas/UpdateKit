import Darwin
import Foundation
import UpdateKitHandOver

// A stand-in helper for UpdateKitHandOverTests: answers each line with who answered it,
// so a test can see the process stay the same while the code running in it changes.
// `HANDOVER_DEMO_SETTLE` shortens the settle time so the tests don't wait two seconds.
// `HANDOVER_DEMO_NO_SIGNAL` leaves SIGUSR1 alone, like a helper from before hand-overs.

let environment = ProcessInfo.processInfo.environment
let settle = environment["HANDOVER_DEMO_SETTLE"].flatMap(Double.init) ?? 2
let launchPath = HandOver.currentExecutablePath() ?? ""
var info = stat()
let inode = stat(launchPath, &info) == 0 ? UInt64(info.st_ino) : 0

let handOver = StdioHandOver(watch: ExecutableWatch.forThisProcess(settle: settle),
                             signal: environment["HANDOVER_DEMO_NO_SIGNAL"] == nil ? SIGUSR1 : nil)
func say(_ text: String) { try? handOver.send(Data(text.utf8)) }

if HandOver.resumed { say("resumed generation=\(HandOver.generation)") }
while let line = handOver.nextLine() {
    let request = String(decoding: line, as: UTF8.self)
    if request == "pause" { usleep(300_000) }
    say("\(request) pid=\(getpid()) generation=\(HandOver.generation) inode=\(inode)")
}
exit(0)
