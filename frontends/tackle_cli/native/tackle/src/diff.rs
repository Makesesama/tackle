//! Diff rows for `edit` tool cards.
//!
//! `similar` owns line matching and intraline emphasis; this module only turns
//! one submitted replacement pair into semantic rows: which side a line belongs
//! to, its number inside the replacement, and which of its tokens changed. The
//! Elixir card owns the palette, wrapping, indentation and truncation, so the
//! same rows serve the inline preview and the F4 inspector.
//!
//! These are previews of the submitted `oldText`/`newText` strings, never of
//! files on disk. Numbers stay relative to the replacement, and unchanged
//! context lines are elided instead of being printed twice.
use rustler::{Encoder, Env, Term};
use similar::{Algorithm, ChangeTag, DiffOp, InlineChangeOptions, TextDiff};
use std::time::{Duration, Instant};

/// Matching is skipped above these bounds. The fallback still prints both
/// sides, but as an unmatched before/after window instead of a diff.
const MAX_MATCH_BYTES: usize = 32_000;
const MAX_MATCH_LINES: usize = 400;
/// Rows one unmatched side may materialize before it is elided. An oversized
/// replacement cannot make the renderer allocate without bound.
const MAX_FALLBACK_ROWS: usize = 1_000;
/// Wall-clock budget for the line diff and for all intraline refinement of one
/// replacement.
const MATCH_BUDGET: Duration = Duration::from_millis(150);

mod atoms {
    rustler::atoms! { del, ins, ctx, elision }
}

/// A semantic diff row; the card decides how it is painted.
pub enum DiffRow {
    /// `{tag, number, spans}`: the side, the 1-based number of the line inside
    /// the submitted replacement, and its `{text, emphasized}` runs.
    Line(RowTag, usize, Vec<(String, bool)>),
    /// `{elision, count}`: `count` unchanged or unprinted lines.
    Elision(usize),
}

/// Which side of the replacement a row belongs to.
#[derive(Clone, Copy)]
pub enum RowTag {
    Del,
    Ins,
    Ctx,
}

impl RowTag {
    fn atom(self) -> rustler::Atom {
        match self {
            RowTag::Del => atoms::del(),
            RowTag::Ins => atoms::ins(),
            RowTag::Ctx => atoms::ctx(),
        }
    }
}

impl Encoder for DiffRow {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            DiffRow::Line(tag, number, spans) => {
                let spans = spans
                    .iter()
                    .map(|(text, emphasized)| (text.as_str(), *emphasized))
                    .collect::<Vec<_>>();
                (tag.atom(), *number, spans).encode(env)
            }
            DiffRow::Elision(count) => (atoms::elision(), *count).encode(env),
        }
    }
}

/// Returns `(added, removed)` line counts and the rows of one replacement.
///
/// `context` keeps that many unchanged lines around every change and elides
/// longer unchanged runs; `0` prints every submitted line. `max_rows` bounds
/// the result to a head/tail window with an elision row between them; `0`
/// returns every row.
pub fn rows(
    old: &str,
    new: &str,
    context: usize,
    max_rows: usize,
) -> ((usize, usize), Vec<DiffRow>) {
    let old_lines = logical_lines(old);
    let new_lines = logical_lines(new);

    let (counts, rows) = if within_match_budget(old, new, &old_lines, &new_lines) {
        matched(&old_lines, &new_lines, context)
    } else {
        unmatched(&old_lines, &new_lines)
    };

    (counts, coalesce(bounded(rows, max_rows)))
}

/// Splits like Elixir's `String.split(text, "\n", trim: false)`, so a
/// replacement that only adds or removes a trailing newline still shows a
/// change instead of looking identical.
fn logical_lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return vec![text];
    }
    text.split('\n').collect()
}

fn within_match_budget(old: &str, new: &str, old_lines: &[&str], new_lines: &[&str]) -> bool {
    old.len() + new.len() <= MAX_MATCH_BYTES && old_lines.len() + new_lines.len() <= MAX_MATCH_LINES
}

fn matched(
    old_lines: &[&str],
    new_lines: &[&str],
    context: usize,
) -> ((usize, usize), Vec<DiffRow>) {
    let diff = TextDiff::configure()
        .algorithm(Algorithm::Myers)
        .timeout(MATCH_BUDGET)
        .diff_slices(old_lines, new_lines);
    let counts = counts(diff.ops());

    if !has_changes(diff.ops()) {
        return (counts, context_rows(new_lines));
    }

    // One deadline for every refinement call, so intraline work stays inside
    // the same budget as the line diff rather than restarting per hunk.
    let deadline = Instant::now() + MATCH_BUDGET;
    let options = inline_options();
    // `grouped_ops` keeps runs of at most `2 * context` lines together, so a
    // very large radius is how "print every submitted line" is expressed.
    let radius = if context == 0 {
        usize::MAX / 4
    } else {
        context
    };

    let mut rows = Vec::new();
    let mut printed = 0;

    for group in diff.grouped_ops(radius) {
        let first = group.first().expect("a grouped hunk is never empty");
        if first.old_range().start > printed {
            rows.push(DiffRow::Elision(first.old_range().start - printed));
        }
        for op in &group {
            for change in
                diff.iter_inline_changes_with_options_deadline(op, options, Some(deadline))
            {
                let (tag, index) = match change.tag() {
                    ChangeTag::Delete => (RowTag::Del, change.old_index()),
                    ChangeTag::Insert => (RowTag::Ins, change.new_index()),
                    ChangeTag::Equal => (RowTag::Ctx, change.new_index()),
                };
                let spans = change
                    .iter_strings_lossy()
                    .map(|(emphasized, text)| (text.into_owned(), emphasized))
                    .collect();
                rows.push(DiffRow::Line(tag, index.unwrap_or_default() + 1, spans));
            }
        }
        printed = group
            .last()
            .expect("a grouped hunk is never empty")
            .old_range()
            .end;
    }

    if old_lines.len() > printed {
        rows.push(DiffRow::Elision(old_lines.len() - printed));
    }

    (counts, rows)
}

/// A replacement too large to match: both sides as a bounded before/after
/// window, in submission order rather than as a diff.
fn unmatched(old_lines: &[&str], new_lines: &[&str]) -> ((usize, usize), Vec<DiffRow>) {
    let rows = block(RowTag::Del, old_lines)
        .into_iter()
        .chain(block(RowTag::Ins, new_lines))
        .collect();

    ((new_lines.len(), old_lines.len()), rows)
}

fn block(tag: RowTag, lines: &[&str]) -> Vec<DiffRow> {
    let rows = lines
        .iter()
        .enumerate()
        .map(|(index, line)| DiffRow::Line(tag, index + 1, plain(line)))
        .collect();

    bounded(rows, MAX_FALLBACK_ROWS)
}

/// Identical sides have no change to isolate, so their lines stay visible as
/// context instead of collapsing into a single unexplained elision row.
fn context_rows(lines: &[&str]) -> Vec<DiffRow> {
    lines
        .iter()
        .enumerate()
        .map(|(index, line)| DiffRow::Line(RowTag::Ctx, index + 1, plain(line)))
        .collect()
}

fn plain(line: &str) -> Vec<(String, bool)> {
    vec![(line.to_owned(), false)]
}

/// Returns `(added, removed)`, counted over every line of the replacement
/// whether or not the printed window still shows it.
fn counts(ops: &[DiffOp]) -> (usize, usize) {
    ops.iter().fold((0, 0), |(added, removed), op| match op {
        DiffOp::Equal { .. } => (added, removed),
        DiffOp::Delete { old_len, .. } => (added, removed + old_len),
        DiffOp::Insert { new_len, .. } => (added + new_len, removed),
        DiffOp::Replace {
            old_len, new_len, ..
        } => (added + new_len, removed + old_len),
    })
}

fn has_changes(ops: &[DiffOp]) -> bool {
    ops.iter().any(|op| !matches!(op, DiffOp::Equal { .. }))
}

fn inline_options() -> InlineChangeOptions {
    let mut options = InlineChangeOptions::new();
    // Emphasis that ends mid-token or overlaps reads as noise.
    options.semantic_cleanup(true);
    options
}

/// Keeps the head and the tail of a block: a bounded window is all a preview
/// can paint, and materializing the rest is wasted work.
fn bounded(rows: Vec<DiffRow>, max_rows: usize) -> Vec<DiffRow> {
    if max_rows == 0 || rows.len() <= max_rows {
        return rows;
    }

    let head = (max_rows - 1) / 2;
    let tail = max_rows - 1 - head;
    let hidden = rows.len() - head - tail;

    let mut rows = rows;
    let tail_rows = rows.split_off(rows.len() - tail);
    let mut window: Vec<DiffRow> = rows.drain(..head).collect();
    window.push(DiffRow::Elision(hidden));
    window.extend(tail_rows);
    window
}

/// Adjacent elisions are one gap: the hunk radius and the row window can both
/// drop lines next to each other.
fn coalesce(rows: Vec<DiffRow>) -> Vec<DiffRow> {
    let mut coalesced: Vec<DiffRow> = Vec::with_capacity(rows.len());

    for row in rows {
        match row {
            DiffRow::Elision(count) => match coalesced.last_mut() {
                Some(DiffRow::Elision(previous)) => *previous += count,
                _ => coalesced.push(DiffRow::Elision(count)),
            },
            row => coalesced.push(row),
        }
    }

    coalesced
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    /// Compact row rendering: `-12 text` with changed tokens in brackets.
    fn lines(rows: &[DiffRow]) -> Vec<String> {
        rows.iter()
            .map(|row| match row {
                DiffRow::Line(tag, number, spans) => {
                    let sign = match tag {
                        RowTag::Del => '-',
                        RowTag::Ins => '+',
                        RowTag::Ctx => ' ',
                    };
                    let text: String = spans
                        .iter()
                        .map(|(text, emphasized)| {
                            if *emphasized {
                                format!("[{text}]")
                            } else {
                                text.clone()
                            }
                        })
                        .collect();
                    format!("{sign}{number} {text}")
                }
                DiffRow::Elision(count) => format!("...{count}"),
            })
            .collect()
    }

    /// The same rows without emphasis markers, for structural assertions.
    fn stripped(rows: &[DiffRow]) -> Vec<String> {
        lines(rows)
            .iter()
            .map(|line| line.replace(['[', ']'], ""))
            .collect()
    }

    fn numbered(prefix: &str, count: usize) -> String {
        (1..=count)
            .map(|index| format!("{prefix}{index}\n"))
            .collect::<String>()
            .trim_end_matches('\n')
            .to_owned()
    }

    #[test]
    fn logical_lines_match_elixir_split_semantics() {
        assert_eq!(logical_lines(""), [""]);
        assert_eq!(logical_lines("a"), ["a"]);
        assert_eq!(logical_lines("a\nb"), ["a", "b"]);
        assert_eq!(logical_lines("a\nb\n"), ["a", "b", ""]);
        assert_eq!(logical_lines("\n"), ["", ""]);
        assert_eq!(logical_lines("\n\n"), ["", "", ""]);
    }
    #[test]
    fn changed_line_keeps_context_numbers_and_is_counted_once() {
        let (counts, rows) = rows("context\nbefore\nend", "context\nafter\nend", 0, 0);

        assert_eq!(counts, (1, 1));
        assert_eq!(
            lines(&rows),
            [" 1 context", "-2 before", "+2 after", " 3 end"]
        );
    }

    #[test]
    fn intraline_emphasis_marks_only_the_changed_tokens() {
        let (counts, rows) = rows("let total = 41", "let total = 42", 0, 0);

        assert_eq!(counts, (1, 1));
        assert_eq!(lines(&rows), ["-1 let total = [41]", "+1 let total = [42]"]);
    }

    #[test]
    fn unrelated_lines_fall_back_to_unemphasized_sides() {
        let (_, rows) = rows("a completely different sentence", "zzz", 0, 0);

        assert_eq!(
            lines(&rows),
            ["-1 a completely different sentence", "+1 zzz"]
        );
    }

    #[test]
    fn inserted_and_deleted_lines_keep_their_own_side_numbers() {
        let (counts, rows) = rows("a\nb\nc", "a\nx\ny\nb\nc", 0, 0);

        assert_eq!(counts, (2, 0));
        // A row carries the number of the side it will read as: what the old
        // text held for a removal, what the replacement holds for the rest.
        assert_eq!(lines(&rows), [" 1 a", "+2 x", "+3 y", " 4 b", " 5 c"]);
    }

    #[test]
    fn hunk_radius_elides_long_unchanged_runs() {
        let old = numbered("line ", 20);
        let new = old.replace("line 10\n", "line ten\n");
        let (counts, rows) = rows(&old, &new, 1, 0);

        assert_eq!(counts, (1, 1));
        assert_eq!(
            lines(&rows),
            [
                "...8",
                " 9 line 9",
                "-10 line [10]",
                "+10 line [ten]",
                " 11 line 11",
                "...9",
            ]
        );

        // Without a radius every submitted line is printed.
        let (_, full) = self::rows(&old, &new, 0, 0);
        assert_eq!(full.len(), 21);
        assert_eq!(lines(&full).first().unwrap(), " 1 line 1");
    }

    #[test]
    fn identical_sides_stay_visible_as_context() {
        let (counts, rows) = rows("keep\nme", "keep\nme", 0, 0);

        assert_eq!(counts, (0, 0));
        assert_eq!(lines(&rows), [" 1 keep", " 2 me"]);
    }

    #[test]
    fn trailing_newline_only_change_still_shows_a_row() {
        let (counts, rows) = rows("a", "a\n", 0, 0);

        assert_eq!(counts, (1, 0));
        assert_eq!(lines(&rows), [" 1 a", "+2 "]);
    }

    #[test]
    fn row_window_keeps_both_ends_and_reports_the_hidden_lines() {
        let old = numbered("old ", 40);
        let new = numbered("new ", 60);
        let (_, rows) = rows(&old, &new, 0, 6);

        assert_eq!(rows.len(), 6);
        let rendered = stripped(&rows);
        assert_eq!(rendered[0], "-1 old 1");
        assert_eq!(rendered[1], "-2 old 2");
        assert_eq!(rendered[3], "+58 new 58");
        assert_eq!(rendered[5], "+60 new 60");
        assert!(rendered[2].starts_with("..."), "{}", rendered[2]);
    }

    #[test]
    fn oversized_replacements_print_a_bounded_before_and_after_window() {
        let old = numbered("old ", 1_200);
        let new = numbered("new ", 1_200);
        let (counts, rows) = rows(&old, &new, 0, 0);

        assert_eq!(counts, (1_200, 1_200));
        assert!(rows.len() <= 2 * MAX_FALLBACK_ROWS);
        let rendered = lines(&rows);
        assert_eq!(rendered[0], "-1 old 1");
        assert_eq!(rendered.last().unwrap(), "+1200 new 1200");
        assert_eq!(
            rendered.iter().filter(|row| row.starts_with("...")).count(),
            2
        );
    }

    #[test]
    fn emoji_and_wide_lines_survive_matching() {
        let (counts, rows) = rows("界 e\u{301} value 1", "界 e\u{301} value 2", 0, 0);

        assert_eq!(counts, (1, 1));
        assert_eq!(
            lines(&rows),
            ["-1 界 e\u{301} value [1]", "+1 界 e\u{301} value [2]"]
        );
    }

    #[test]
    fn adversarial_replacement_returns_within_its_budget() {
        let old = (0..400)
            .map(|index| format!("{}{}\n", "a".repeat(index % 7), index))
            .collect::<String>();
        let new = (0..400)
            .map(|index| format!("{}{}\n", "b".repeat(index % 5), 400 - index))
            .collect::<String>();

        let started = Instant::now();
        let (counts, rows) = rows(&old, &new, 3, 6);

        assert_eq!(rows.len(), 6);
        assert!(counts.1 >= 400);
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
