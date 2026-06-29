//! Skipping the next workout forward/backward through the rotation moves only
//! the cursor — no record is written and the lanes never move (ADR 0007).

use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::{init_training_repo, read_records, read_state, skip_workout_repo};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-{name}-{nanos}"))
}

#[test]
fn skip_forward_advances_the_cursor_without_recording_or_progressing() {
    let root = temp_repo("skip-forward");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    let before = read_state(&root).unwrap();
    assert_eq!(before.cursor.next_session, "a1");

    let outputs = skip_workout_repo(&root, true).unwrap();

    // Cursor moved to the next rotation slot (A1 -> B1)...
    assert_eq!(outputs.state.cursor.next_session, "b1");
    assert_eq!(outputs.next_workout.as_ref().unwrap().session_id, "b1");
    // ...persisted to disk...
    let after = read_state(&root).unwrap();
    assert_eq!(after.cursor.next_session, "b1");
    assert_eq!(after.cursor.week, 1);
    // ...with the lanes untouched and nothing logged.
    assert_eq!(after.lanes, before.lanes);
    assert!(read_records(&root).unwrap().is_empty());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn skipping_to_the_end_of_the_rotation_rolls_over_to_the_next_week() {
    let root = temp_repo("skip-week-rollover");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    // rotation A1 B1 A2 B2: four forward skips return to A1 in week 2.
    for expected in ["b1", "a2", "b2", "a1"] {
        let outputs = skip_workout_repo(&root, true).unwrap();
        assert_eq!(outputs.state.cursor.next_session, expected);
    }
    assert_eq!(read_state(&root).unwrap().cursor.week, 2);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn skipping_back_and_forth_is_reversible() {
    let root = temp_repo("skip-reversible");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    skip_workout_repo(&root, true).unwrap(); // A1 -> B1
    skip_workout_repo(&root, true).unwrap(); // B1 -> A2
    let back = skip_workout_repo(&root, false).unwrap(); // A2 -> B1
    assert_eq!(back.state.cursor.next_session, "b1");
    let back = skip_workout_repo(&root, false).unwrap(); // B1 -> A1
    assert_eq!(back.state.cursor.next_session, "a1");
    assert_eq!(read_state(&root).unwrap().cursor.week, 1);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn going_back_past_the_first_workout_rolls_back_a_week_then_floors() {
    let root = temp_repo("skip-back-floor");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    // Move into week 2 (A1 of week 2), then step back across the boundary.
    for _ in 0..4 {
        skip_workout_repo(&root, true).unwrap();
    }
    assert_eq!(read_state(&root).unwrap().cursor.week, 2);

    let back = skip_workout_repo(&root, false).unwrap(); // week2 A1 -> week1 B2
    assert_eq!(back.state.cursor.next_session, "b2");
    assert_eq!(back.state.cursor.week, 1);

    // Walk back to the program's very first workout, then confirm "back" is a no-op.
    for expected in ["a2", "b1", "a1"] {
        let back = skip_workout_repo(&root, false).unwrap();
        assert_eq!(back.state.cursor.next_session, expected);
    }
    let floored = skip_workout_repo(&root, false).unwrap();
    assert_eq!(floored.state.cursor.next_session, "a1");
    assert_eq!(floored.state.cursor.week, 1);

    let _ = std::fs::remove_dir_all(&root);
}
