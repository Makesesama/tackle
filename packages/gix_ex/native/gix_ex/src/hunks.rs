//! Line diffs of two blobs, grouped into unified-diff hunks.
//!
//! Hunks follow `git diff -U<n>`: changes closer than `2 * n` unchanged lines
//! share a hunk, a side without lines starts at the line before the hunk, and
//! the section heading is found with Git's default function-name rule (see
//! [`section`]).

use gix::diff::blob::{Algorithm as Imara, Diff, InternedInput};

use crate::terms::{Algorithm, Bytes, Hunk, Line, LineKind};

/// Git's buffer for a hunk's section heading.
const SECTION_BYTES: usize = 80;

pub struct Lines {
    pub hunks: Vec<Hunk>,
    pub additions: u32,
    pub deletions: u32,
}

/// Diffs `old` against `new` line by line, with `context` lines around
/// each change.
pub fn diff(old: &[u8], new: &[u8], context: u32, algorithm: Algorithm) -> Lines {
    let input = InternedInput::new(old, new);
    let algorithm = match algorithm {
        Algorithm::Myers => Imara::Myers,
        Algorithm::Histogram => Imara::Histogram,
    };
    let mut diff = Diff::compute(algorithm, &input);
    diff.postprocess_lines(&input);

    let before: Vec<&[u8]> = input
        .before
        .iter()
        .map(|token| input.interner[*token])
        .collect();
    let after: Vec<&[u8]> = input
        .after
        .iter()
        .map(|token| input.interner[*token])
        .collect();

    let changes: Vec<(std::ops::Range<u32>, std::ops::Range<u32>)> =
        diff.hunks().map(|hunk| (hunk.before, hunk.after)).collect();

    let mut builder = Builder {
        before: &before,
        after: &after,
        context,
        section: Vec::new(),
        section_searched_to: -1,
    };

    let mut hunks = Vec::new();
    let mut additions = 0;
    let mut deletions = 0;
    let mut start = 0;

    for index in 1..=changes.len() {
        let split = index == changes.len()
            || u64::from(changes[index].0.start - changes[index - 1].0.end)
                > 2 * u64::from(context);

        if split {
            let hunk = builder.hunk(&changes[start..index]);
            for line in &hunk.lines {
                match line.kind {
                    LineKind::Add => additions += 1,
                    LineKind::Remove => deletions += 1,
                    LineKind::Context => {}
                }
            }
            hunks.push(hunk);
            start = index;
        }
    }

    Lines {
        hunks,
        additions,
        deletions,
    }
}

struct Builder<'a> {
    before: &'a [&'a [u8]],
    after: &'a [&'a [u8]],
    context: u32,
    /// The heading of the previous hunk, which Git keeps when no new one is
    /// found between two hunks.
    section: Vec<u8>,
    /// The old line (0-based) the previous heading search started from.
    section_searched_to: i64,
}

type Change = (std::ops::Range<u32>, std::ops::Range<u32>);

impl Builder<'_> {
    fn hunk(&mut self, changes: &[Change]) -> Hunk {
        let (first_before, first_after) = &changes[0];
        let (last_before, _last_after) = &changes[changes.len() - 1];

        // Lines before the first and after the last change are common to both
        // sides, so the same amount of context fits on either side.
        let leading = self.context.min(first_before.start);
        let trailing = self.context.min(self.before.len() as u32 - last_before.end);

        let old_from = first_before.start - leading;
        let new_from = first_after.start - leading;

        let mut lines = Vec::new();
        let (mut old, mut new) = (old_from, new_from);

        for (before, after) in changes {
            while old < before.start {
                lines.push(self.context_line(old, new));
                old += 1;
                new += 1;
            }
            for index in before.clone() {
                lines.push(line(
                    LineKind::Remove,
                    Some(index + 1),
                    None,
                    self.before[index as usize],
                ));
            }
            for index in after.clone() {
                lines.push(line(
                    LineKind::Add,
                    None,
                    Some(index + 1),
                    self.after[index as usize],
                ));
            }
            old = before.end;
            new = after.end;
        }

        for _ in 0..trailing {
            lines.push(self.context_line(old, new));
            old += 1;
            new += 1;
        }

        let old_count = old - old_from;
        let new_count = new - new_from;
        // Git numbers an empty side by the line before it, so an insertion
        // after line 5 is `-5,0` and a new file is `-0,0`.
        let old_start = if old_count == 0 {
            old_from
        } else {
            old_from + 1
        };
        let new_start = if new_count == 0 {
            new_from
        } else {
            new_from + 1
        };

        let section = self.section(old_from);

        Hunk {
            header: Bytes(header(old_start, old_count, new_start, new_count, &section)),
            old_start,
            old_count,
            new_start,
            new_count,
            section: Bytes(section),
            lines,
        }
    }

    fn context_line(&self, old: u32, new: u32) -> Line {
        line(
            LineKind::Context,
            Some(old + 1),
            Some(new + 1),
            self.before[old as usize],
        )
    }

    /// Git's default `funcname` rule: the nearest old line above the hunk that
    /// starts with a letter, `_`, or `$`, cut to at most 80 bytes and stripped of
    /// trailing whitespace. The search does not go back past the previous
    /// hunk's start; without a match, the previous heading is kept.
    fn section(&mut self, old_from: u32) -> Vec<u8> {
        let start = i64::from(old_from) - 1;
        let limit = self.section_searched_to;
        self.section_searched_to = start;

        let mut index = start;
        while index != limit && index >= 0 && (index as usize) < self.before.len() {
            if let Some(heading) = function_line(self.before[index as usize]) {
                self.section = heading;
                break;
            }
            index -= 1;
        }

        self.section.clone()
    }
}

fn function_line(line: &[u8]) -> Option<Vec<u8>> {
    match line.first() {
        Some(byte) if byte.is_ascii_alphabetic() || *byte == b'_' || *byte == b'$' => {
            // Cut at a character boundary, as Git does, rather than in the
            // middle of a UTF-8 sequence.
            let mut end = line.len().min(SECTION_BYTES);
            while end < line.len() && end > 0 && line[end] & 0xC0 == 0x80 {
                end -= 1;
            }
            let mut heading = &line[..end];
            while let Some((last, rest)) = heading.split_last() {
                if is_c_space(*last) {
                    heading = rest;
                } else {
                    break;
                }
            }
            Some(heading.to_vec())
        }
        _ => None,
    }
}

/// C's `isspace` in the C locale, which Git uses for trimming.
pub fn is_c_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r')
}

fn line(kind: LineKind, old: Option<u32>, new: Option<u32>, raw: &[u8]) -> Line {
    let (text, no_newline) = match raw.strip_suffix(b"\n") {
        Some(text) => (text, false),
        None => (raw, true),
    };

    Line {
        kind,
        old,
        new,
        text: Bytes::from(text),
        no_newline,
    }
}

fn header(
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: &[u8],
) -> Vec<u8> {
    let mut header = format!(
        "@@ -{} +{} @@",
        range(old_start, old_count),
        range(new_start, new_count)
    )
    .into_bytes();

    if !section.is_empty() {
        header.push(b' ');
        header.extend_from_slice(section);
    }

    header
}

fn range(start: u32, count: u32) -> String {
    if count == 1 {
        start.to_string()
    } else {
        format!("{start},{count}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(lines: &Lines) -> String {
        let mut out = String::new();
        for hunk in &lines.hunks {
            out.push_str(&String::from_utf8_lossy(&hunk.header.0));
            out.push('\n');
            for line in &hunk.lines {
                out.push(match line.kind {
                    LineKind::Add => '+',
                    LineKind::Remove => '-',
                    LineKind::Context => ' ',
                });
                out.push_str(&String::from_utf8_lossy(&line.text.0));
                out.push('\n');
                if line.no_newline {
                    out.push_str("\\ No newline at end of file\n");
                }
            }
        }
        out
    }

    #[test]
    fn new_file() {
        let lines = diff(b"", b"a\nb\n", 3, Algorithm::Myers);
        assert_eq!(render(&lines), "@@ -0,0 +1,2 @@\n+a\n+b\n");
        assert_eq!((lines.additions, lines.deletions), (2, 0));
    }

    #[test]
    fn missing_newline() {
        let lines = diff(b"a\nb", b"a\nc\n", 3, Algorithm::Myers);
        assert_eq!(
            render(&lines),
            "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c\n"
        );
    }

    #[test]
    fn separate_hunks_and_sections() {
        let old: Vec<u8> = (1..=20)
            .map(|n| format!("    line {n}\n"))
            .collect::<String>()
            .into_bytes();
        let old = [b"fn main() {\n".as_slice(), &old].concat();
        let new = String::from_utf8(old.clone())
            .unwrap()
            .replace("    line 3\n", "    three\n")
            .replace("    line 17\n", "    seventeen\n");
        let lines = diff(&old, new.as_bytes(), 3, Algorithm::Myers);

        assert_eq!(lines.hunks.len(), 2);
        assert_eq!(lines.hunks[0].header.0, b"@@ -1,7 +1,7 @@");
        assert_eq!(lines.hunks[1].header.0, b"@@ -15,7 +15,7 @@ fn main() {");
    }

    #[test]
    fn section_is_cut_at_a_character_boundary() {
        let heading = format!("x{}", "─".repeat(40));
        let cut = function_line(heading.as_bytes()).unwrap();
        // 1 + 26 * 3 = 79 bytes; the 27th character would end at byte 82.
        assert_eq!(cut.len(), 79);
        assert!(std::str::from_utf8(&cut).is_ok());
    }

    #[test]
    fn insertion_without_context() {
        let lines = diff(b"a\nb\n", b"a\nx\nb\n", 0, Algorithm::Myers);
        assert_eq!(render(&lines), "@@ -1,0 +2 @@ a\n+x\n");
    }
}
