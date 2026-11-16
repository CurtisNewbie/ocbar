import Foundation

// The pure seams under the island's surfaces, in one runner:
// 1. the head selection of the card's question queue (Models.swift's `islandQuestionHead`): rows in
//    ranked order, arrival order within and across them, and the form the user hid;
// 2. the reminders a tick publishes (Models.swift's `reminderEvents`): which session each dismissal and
//    transition is about, and the order they fire in.

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

// MARK: - Reminders

// Every dismissal and transition names the session it is about. Two sessions in one folder are two
// independent reminders, so the folder is carried beside the id and never stands in for it.

func session(_ id: String, _ status: SessionStatus, dir: String = "/p",
             pid: Int32? = nil, title: String? = nil) -> SessionInfo {
    SessionInfo(id: id, status: status, projectDir: dir, clientPID: pid, sessionTitle: title)
}

func dismissals(_ events: [ReminderEvent]) -> [SessionReminder] {
    events.compactMap { event in
        guard case .dismiss(let reminder) = event else { return nil }
        return reminder
    }
}

func transitions(_ events: [ReminderEvent])
    -> [(kind: SessionStatus, reminder: SessionReminder, pid: Int32?, title: String?)] {
    events.compactMap { event in
        guard case .transition(let kind, let reminder, let pid, let title) = event else { return nil }
        return (kind, reminder, pid, title)
    }
}

// 1. The defect: two sessions in one folder, one stops waiting. Only that session's reminder is
//    dismissed; the other's stays armed.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .waiting, "ses_b": .waiting],
        previousDir: ["ses_a": "/p", "ses_b": "/p"],
        sessions: [session("ses_a", .idle), session("ses_b", .waiting)]
    )
    check("a session that stops waiting is dismissed by its own id, not its folder",
          dismissals(events).map(\.sessionID) == ["ses_a"], "got \(events)")
    check("the other waiting session in the same folder publishes nothing", events.count == 1,
          "got \(events)")
    check("the dismissal still carries the project directory",
          dismissals(events).first?.projectDir == "/p", "got \(events)")
}

// 2. Waiting → busy: the prompt was answered and the agent went back to work.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .waiting],
        previousDir: ["ses_a": "/p"],
        sessions: [session("ses_a", .busy)]
    )
    check("waiting to busy dismisses that session",
          dismissals(events).map(\.sessionID) == ["ses_a"], "got \(events)")
    check("waiting to busy announces nothing", transitions(events).isEmpty, "got \(events)")
}

// 3. Idle → busy: the user started a new turn, so the ready reminder is stale.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .idle],
        previousDir: ["ses_a": "/p"],
        sessions: [session("ses_a", .busy)]
    )
    check("idle to busy dismisses that session",
          dismissals(events).map(\.sessionID) == ["ses_a"], "got \(events)")
    check("idle to busy announces nothing", transitions(events).isEmpty, "got \(events)")
}

// 4. Busy → idle: the ready reminder, about that session, and carrying the row the island marks and
//    the title the bubble shows.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .busy],
        previousDir: ["ses_a": "/p"],
        sessions: [session("ses_a", .idle, pid: 4242, title: "Refactor the parser")]
    )
    let announced = transitions(events)
    check("busy to idle announces the ready transition for that session",
          announced.count == 1 && announced[0].kind == .idle
            && announced[0].reminder.sessionID == "ses_a", "got \(events)")
    check("the ready transition carries the session's client pid, which the row mark is spent on",
          announced.first?.pid == 4242, "got \(events)")
    check("the ready transition carries the session's title",
          announced.first?.title == "Refactor the parser", "got \(events)")
    check("busy to idle dismisses nothing", dismissals(events).isEmpty, "got \(events)")
}

// 5. Idle → waiting: the needs-input reminder, about that session.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .idle],
        previousDir: ["ses_a": "/p"],
        sessions: [session("ses_a", .waiting, pid: 4242, title: "Refactor the parser")]
    )
    let announced = transitions(events)
    check("idle to waiting announces the needs-input transition for that session",
          announced.count == 1 && announced[0].kind == .waiting
            && announced[0].reminder.sessionID == "ses_a", "got \(events)")
    check("the needs-input transition carries the session's client pid and title",
          announced.first?.pid == 4242 && announced.first?.title == "Refactor the parser",
          "got \(events)")
    check("idle to waiting dismisses nothing", dismissals(events).isEmpty, "got \(events)")
}

// 6. Waiting → idle: the reminder is retracted, and no ready reminder replaces it — the session was
//    already waiting for the user, so going idle is the answer, not news.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .waiting],
        previousDir: ["ses_a": "/p"],
        sessions: [session("ses_a", .idle)]
    )
    check("waiting to idle dismisses that session",
          dismissals(events).map(\.sessionID) == ["ses_a"], "got \(events)")
    check("waiting to idle announces no ready transition", transitions(events).isEmpty, "got \(events)")
}

// 7. A session that left the list: dismissed by its id, carrying the directory it was last seen in.
do {
    let events = reminderEvents(
        previousStatus: ["ses_gone": .busy],
        previousDir: ["ses_gone": "/gone"],
        sessions: [session("ses_here", .idle)]
    )
    check("a vanished session is dismissed by its own id",
          dismissals(events) == [SessionReminder(sessionID: "ses_gone", projectDir: "/gone")],
          "got \(events)")
    check("a vanished session's dismissal is the tick's only event", events.count == 1,
          "got \(events)")
}

// 8. Order: the vanished sessions first, then the visible ones in the monitor's order.
do {
    let events = reminderEvents(
        previousStatus: ["ses_gone": .busy, "ses_a": .idle],
        previousDir: ["ses_gone": "/gone", "ses_a": "/p"],
        sessions: [session("ses_a", .waiting)]
    )
    check("a vanished session is dismissed before the visible sessions' events",
          events.count == 2 && dismissals(Array(events.prefix(1))).count == 1
            && transitions(Array(events.suffix(1))).count == 1, "got \(events)")
}

// 9. No status change: nothing is published at all.
do {
    let events = reminderEvents(
        previousStatus: ["ses_a": .waiting, "ses_b": .busy],
        previousDir: ["ses_a": "/p", "ses_b": "/q"],
        sessions: [session("ses_a", .waiting), session("ses_b", .busy), session("ses_c", .error)]
    )
    check("a session whose status does not change publishes nothing", events.isEmpty, "got \(events)")
}

print(failures == 0 ? "\(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
