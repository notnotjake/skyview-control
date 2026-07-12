import Foundation

/// Overwrite-style keypad entry over an HH:MM time, modeled on how the
/// system date pickers take typed input: a caret walks the digit positions
/// left to right — hour, minute tens, minute ones — and each typed digit
/// overwrites its position, leaving the rest of the time intact. So with
/// 11:15 fully selected, typing 9, 3, 0 reads 9:15 → 9:35 → 9:30.
///
/// A fresh entry starts with the whole time selected; tapping a segment
/// narrows the selection to just the hour or the minutes. Typing always
/// collapses the selection onto the caret. The meridiem is never touched —
/// typed hours keep the field's current AM/PM.
struct TimeKeypadEntry: Equatable {
    enum Caret: Equatable {
        case hour, minuteTens, minuteOnes
    }

    private(set) var caret: Caret = .hour
    /// Whole-time selection: the visual state right after focusing, before
    /// the first digit. Typing behaves exactly as caret-at-hour.
    private(set) var selectsAll = true
    /// A typed "1" that may still extend to 10/11/12 with the next digit.
    private(set) var hourPending = false

    var hourSelected: Bool { !selectsAll && caret == .hour }
    var minutesSelected: Bool { !selectsAll && caret != .hour }

    mutating func selectAll() {
        self = TimeKeypadEntry()
    }

    mutating func selectHour() {
        caret = .hour
        selectsAll = false
        hourPending = false
    }

    mutating func selectMinutes() {
        caret = .minuteTens
        selectsAll = false
        hourPending = false
    }

    /// Steps the caret back one position; from the hour it widens back out
    /// to the whole-time selection.
    mutating func backspace() {
        hourPending = false
        switch caret {
        case .minuteOnes: caret = .minuteTens
        case .minuteTens: caret = .hour
        case .hour: selectsAll = true
        }
    }

    /// Applies one typed digit to `minute` (minutes since midnight) and
    /// advances the caret, returning the updated time.
    ///
    /// Hour position: 2–9 commit immediately and move to the minutes
    /// (no valid hour continues from them); 1 commits but waits — a
    /// following 0–2 upgrades it to 10/11/12, anything else starts the
    /// minutes. Minute tens: 6–9 can only be a ones digit, so they write
    /// ":0d" and finish. After the last digit the whole time re-selects,
    /// ready to be typed over again.
    mutating func apply(digit: Int, to minute: Int) -> Int {
        let isPM = minute >= 720
        var hour12 = (minute / 60) % 12 == 0 ? 12 : (minute / 60) % 12
        var mins = minute % 60
        selectsAll = false

        switch caret {
        case .hour:
            if hourPending {
                hourPending = false
                caret = .minuteTens
                if digit <= 2 {
                    hour12 = 10 + digit
                } else {
                    // The 1 stands as the hour; this digit is the minutes'.
                    return apply(digit: digit, to: minute)
                }
            } else if digit == 1 {
                hour12 = 1
                hourPending = true
            } else if digit == 0 {
                // No 0 hour on a 12-hour clock; swallow the leading zero.
                return minute
            } else {
                hour12 = digit
                caret = .minuteTens
            }
        case .minuteTens:
            if digit <= 5 {
                mins = digit * 10 + mins % 10
                caret = .minuteOnes
            } else {
                mins = digit
                selectAll()
            }
        case .minuteOnes:
            mins = (mins / 10) * 10 + digit
            selectAll()
        }

        let hour24 = (hour12 % 12) + (isPM ? 12 : 0)
        return hour24 * 60 + mins
    }
}
