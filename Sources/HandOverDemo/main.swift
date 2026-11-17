import Darwin
import Foundation
import UpdateKitHandOver

// A stand-in helper for UpdateKitHandOverTests: answers each line with who answered it,
// so a test can see the process stay the same while the code running in it changes.
// `HANDOVER_DEMO_SETTLE` shortens the settle time so the tests don't wait two seconds.
// `HANDOVER_DEMO_NO_SIGNAL` leaves SIGUSR1 alone, like a helper from before hand-overs.
// `HANDOVER_DEMO_CONCURRENT` serves each request on a thread of its own, as an MCP server
// that runs tool calls in parallel does; a request starting with "slow" takes a second.

let environment = ProcessInfo.processInfo.environment
let settle = environment["HANDOVER_DEMO_SETTLE"].flatMap(Double.init) ?? 2
let launchPath = HandOver.currentExecutablePath() ?? ""
var info = stat()
let inode = stat(launchPath, &info) == 0 ? UInt64(info.st_ino) : 0

let handOver = StdioHandOver(watch: ExecutableWatch.forThisProcess(settle: settle),
                             signal: environment["HANDOVER_DEMO_NO_SIGNAL"] == nil ? SIGUSR1 : nil)
func say(_ text: String) { try? handOver.send(Data(text.utf8)) }

func answer(_ request: String) -> String {
    "\(request) pid=\(getpid()) generation=\(HandOver.generation) inode=\(inode)"
}

if HandOver.resumed { say("resumed generation=\(HandOver.generation)") }
if environment["HANDOVER_DEMO_CONCURRENT"] != nil {
    while let request = handOver.nextRequest() {
        let text = String(decoding: request.line, as: UTF8.self)
        Thread.detachNewThread {
            if text.hasPrefix("slow") { usleep(1_000_000) }
            say(answer(text))
            request.finish()
        }
    }
    // Answer what is still in flight before going.
    while handOver.requestsInFlight > 0 { usleep(10_000) }
    exit(0)
}
while let line = handOver.nextLine() {
    let request = String(decoding: line, as: UTF8.self)
    if request == "pause" { usleep(300_000) }
    say(answer(request))
}
exit(0)
