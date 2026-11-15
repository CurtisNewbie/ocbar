import Foundation

// The head selection of the card's question queue (Models.swift's `islandQuestionHead`), pinned as a
// pure seam: rows in ranked order, arrival order within and across them, and the form the user hid.

var failures = 0
var checks = 0

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if passed {
        print("PASS  \(name)")
    } else {
        failures += 1
        let note = detail()
        print("FAIL  \(name)\(note.isEmpty ? "" : " — \(note)")")
    }
}

func form(_ id: String, arrival: UInt64) -> PendingQuestion {
    PendingQuestion(id: id, sessionID: "ses_1", fields: [], answerable: true,
                    payload: "p", arrival: arrival)
}

func headResult(_ queues: [[PendingQuestion]], hidden: Set<String>) -> (id: String?, count: Int) {
    let head = islandQuestionHead(in: queues, hidden: hidden)
    return (head.form?.id, head.count)
}

// 1. Nothing pending.
do {
    let result = headResult([], hidden: [])
    check("empty queues ask nothing and count nothing", result.id == nil && result.count == 0,
          "got id \(String(describing: result.id)), count \(result.count)")
}

// 2. No hidden form: the oldest arrival across rows wins, and every form counts.
do {
    let rows = [[form("frm_late", arrival: 5)], [form("frm_early", arrival: 2), form("frm_mid", arrival: 3)]]
    let result = headResult(rows, hidden: [])
    check("oldest arrival takes the card across rows", result.id == "frm_early",
          "got \(String(describing: result.id))")
    check("no hidden form counts every pending form", result.count == 3, "got \(result.count)")
}

// 3. The hidden form is the oldest of its row: the next one in that row takes the card.
do {
    let rows = [[form("frm_a", arrival: 1), form("frm_b", arrival: 2)]]
    let result = headResult(rows, hidden: ["frm_a"])
    check("hiding the oldest of a row offers the next in that row", result.id == "frm_b",
          "got \(String(describing: result.id))")
    check("the hidden form is not counted", result.count == 1, "got \(result.count)")
}

// 4. The hidden form is the oldest overall, in another row than the one that must take over.
do {
    let rows = [[form("frm_a", arrival: 1)], [form("frm_b", arrival: 2)]]
    let result = headResult(rows, hidden: ["frm_a"])
    check("hiding the oldest overall offers the next oldest, in another row", result.id == "frm_b",
          "got \(String(describing: result.id))")
    check("the hidden form leaves the other row's count alone", result.count == 1, "got \(result.count)")
}

// 5. A non-oldest form is hidden: the oldest still wins, and the hidden one is not counted.
do {
    let rows = [[form("frm_a", arrival: 1), form("frm_b", arrival: 2)]]
    let result = headResult(rows, hidden: ["frm_b"])
    check("hiding a later form keeps the oldest on the card", result.id == "frm_a",
          "got \(String(describing: result.id))")
    check("a hidden later form is not counted", result.count == 1, "got \(result.count)")
}

// 6. A hidden id that is pending nowhere changes nothing.
do {
    let rows = [[form("frm_a", arrival: 1)], [form("frm_b", arrival: 2)]]
    let result = headResult(rows, hidden: ["frm_gone"])
    check("an absent hidden id leaves the head alone", result.id == "frm_a",
          "got \(String(describing: result.id))")
    check("an absent hidden id leaves the count alone", result.count == 2, "got \(result.count)")
}

// 7. Two forms hidden: neither returns, and the third takes the card.
do {
    let rows = [[form("frm_a", arrival: 1), form("frm_b", arrival: 2)], [form("frm_c", arrival: 3)]]
    let result = headResult(rows, hidden: ["frm_a", "frm_b"])
    check("a second Hide leaves the first hidden form out of the queue", result.id == "frm_c",
          "got \(String(describing: result.id))")
    check("only the forms the card may still show are counted", result.count == 1, "got \(result.count)")
}

// 8. Hiding the only pending form leaves nothing to ask.
do {
    let result = headResult([[form("frm_a", arrival: 1)]], hidden: ["frm_a"])
    check("hiding the only form asks nothing", result.id == nil,
          "got \(String(describing: result.id))")
    check("hiding the only form counts nothing", result.count == 0, "got \(result.count)")
}

print(failures == 0 ? "\(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
