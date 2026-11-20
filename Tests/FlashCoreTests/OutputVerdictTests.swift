import Testing
@testable import FlashCore

@Suite struct OutputVerdictTests {

    static let printed = [
        "security find-generic-password -s api -w",
        "security find-generic-password -s api -w | head -c 4",
        "security find-generic-password -s api -w 2>/dev/null",
        "security find-generic-password -s api -w >&2",
        "echo start; security find-internet-password -s host -g",
        "X=$(security find-generic-password -s a -w); security find-generic-password -s b -w",
    ]

    static let captured = [
        "security find-generic-password -s api -w >/dev/null",
        "security find-generic-password -s api -w > key.txt && echo done",
        "security find-generic-password -s api -w >> key.txt",
        "security find-generic-password -s api -w &>/dev/null",
        "security find-generic-password -s api -w 1>/dev/null 2>&1",
        "security find-generic-password -s api -w | pbcopy",
        "TOKEN=$(security find-generic-password -s api -w)",
        "security find-generic-password -s api",
        "( security find-generic-password -s 'a b' -w >/dev/null 2>err & echo $! )",
    ]

    @Test(arguments: printed) func printedValue(_ command: String) {
        #expect(OutputVerdict.printsKeychainValue(command))
    }

    @Test(arguments: captured) func valueNotPrinted(_ command: String) {
        #expect(!OutputVerdict.printsKeychainValue(command))
    }
}
