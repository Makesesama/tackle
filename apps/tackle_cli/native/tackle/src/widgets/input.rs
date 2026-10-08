//! Tackle's editor core. The host owns submission and shortcut precedence.
//! Byte offsets always fall on grapheme boundaries; one layout drives measure,
//! vertical movement, scrolling and paint (including the final insertion cell).
//!
//! An *element* is a byte range the host inserted as one unit — a collapsed
//! paste label. Elements are atomic: motion steps over one, an edit that
//! touches one removes it whole, and paint gives it its own style. The host
//! owns identity: an element carries the id it was inserted with, and only the
//! host knows what that id stands for.
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::Span,
};
use std::collections::VecDeque;

#[derive(Clone, Default)]
struct Draft {
    text: String,
    cursor: usize,
}

/// One host-inserted range, identified by the host's id for its payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Element {
    id: u64,
    start: usize,
    end: usize,
}

/// An element as the host sees it: `{id, byte_start, byte_end}`.
pub type WireElement = (u64, usize, usize);

/// A draft and its elements, as one undo step or one host restore.
#[derive(Clone, Default)]
struct Snapshot {
    draft: Draft,
    elements: Vec<Element>,
}

#[derive(Default)]
pub struct Input {
    draft: Draft,
    elements: Vec<Element>,
    undo: VecDeque<Snapshot>,
    redo: VecDeque<Snapshot>,
    preferred_column: Option<usize>,
    scroll: usize,
}

struct Glyph<'a> {
    start: usize,
    end: usize,
    symbol: &'a str,
    width: usize,
}

// Use Ratatui's own grapheme and width rules, without another Unicode stack.
// Controls retain editable offsets but never reach terminal cells verbatim.
fn glyphs(text: &str) -> Vec<Glyph<'_>> {
    let mut result = Vec::new();
    let mut offset = 0;
    for chunk in text.split_inclusive(char::is_control) {
        let control = chunk.chars().last().filter(|c| c.is_control());
        let printable_len = chunk.len() - control.map_or(0, char::len_utf8);
        let span = Span::raw(&chunk[..printable_len]);
        let mut start = offset;
        for grapheme in span.styled_graphemes(Style::new()) {
            result.push(Glyph {
                start,
                end: start + grapheme.symbol.len(),
                symbol: &text[start..start + grapheme.symbol.len()],
                width: Span::raw(grapheme.symbol).width(),
            });
            start += grapheme.symbol.len();
        }
        if let Some(c) = control {
            result.push(Glyph {
                start: offset + printable_len,
                end: offset + chunk.len(),
                symbol: match c {
                    '\n' => "\n",
                    '\t' => " ",
                    _ => "�",
                },
                width: 1,
            });
        }
        offset += chunk.len();
    }
    result
}

#[derive(Debug)]
struct Stop {
    byte: usize,
    row: usize,
    col: usize,
}

struct Layout<'a> {
    glyphs: Vec<(Glyph<'a>, usize, usize)>,
    stops: Vec<Stop>,
    rows: usize,
}

fn is_whitespace(glyph: &Glyph<'_>) -> bool {
    glyph.symbol.chars().all(char::is_whitespace)
}

// Host-provided offsets may sit inside a multi-byte grapheme; walk back to the
// nearest boundary so replace_range can never split one.
fn floor_boundary(text: &str, pos: usize) -> usize {
    let mut pos = pos.min(text.len());
    while pos > 0 && !text.is_char_boundary(pos) {
        pos -= 1;
    }
    pos
}

fn previous_word_start(glyphs: &[Glyph<'_>], cursor: usize) -> usize {
    let mut start = cursor;
    let mut seen_word = false;
    for glyph in glyphs.iter().rev().filter(|glyph| glyph.start < cursor) {
        let whitespace = is_whitespace(glyph);
        if seen_word && whitespace {
            break;
        }
        seen_word |= !whitespace;
        start = glyph.start;
    }
    start
}

fn next_word_end(glyphs: &[Glyph<'_>], cursor: usize) -> usize {
    let mut end = cursor;
    let mut seen_word = false;
    for glyph in glyphs.iter().filter(|glyph| glyph.start >= cursor) {
        let whitespace = is_whitespace(glyph);
        if seen_word && whitespace {
            break;
        }
        seen_word |= !whitespace;
        end = glyph.end;
    }
    end
}

fn layout(text: &str, width: u16) -> Layout<'_> {
    let width = usize::from(width.max(1));
    let mut row = 0;
    let mut col = 0;
    let mut placed = Vec::new();
    let mut stops = Vec::new();
    for glyph in glyphs(text) {
        if glyph.symbol != "\n" && col > 0 && col + glyph.width.max(1) > width {
            row += 1;
            col = 0;
        }
        stops.push(Stop {
            byte: glyph.start,
            row,
            col,
        });
        if glyph.symbol == "\n" {
            row += 1;
            col = 0;
        } else {
            let cells = glyph.width.max(1).min(width);
            placed.push((glyph, row, col));
            col += cells;
            if col >= width {
                row += 1;
                col = 0;
            }
        }
    }
    stops.push(Stop {
        byte: text.len(),
        row,
        col,
    });
    Layout {
        glyphs: placed,
        stops,
        rows: row + 1,
    }
}

// Bound retained snapshots by both edit count and bytes. A huge current draft
// remains editable, but does not force an unbounded undo archive. Elements are
// part of a snapshot, so their (small) metadata counts against the budget too.
fn remember(history: &mut VecDeque<Snapshot>, snapshot: Snapshot) {
    const BUDGET: usize = 8 * 1024 * 1024;
    let weigh =
        |s: &Snapshot| s.draft.text.len() + s.elements.len() * std::mem::size_of::<Element>();
    history.push_back(snapshot);
    let mut bytes: usize = history.iter().map(weigh).sum();
    while history.len() > 100 || bytes > BUDGET {
        bytes -= weigh(&history.pop_front().unwrap());
    }
}

impl Input {
    pub fn value(&self) -> &str {
        &self.draft.text
    }

    /// The host's ids for the current labels, with the byte range each spans.
    pub fn elements(&self) -> Vec<WireElement> {
        self.elements
            .iter()
            .map(|element| (element.id, element.start, element.end))
            .collect()
    }

    pub fn set(&mut self, text: String) {
        self.draft = Draft {
            cursor: text.len(),
            text,
        };
        self.elements.clear();
        self.undo.clear();
        self.redo.clear();
        self.preferred_column = None;
        self.scroll = 0;
    }

    /// Replaces the draft and re-attaches the label spans the host recorded for
    /// it, returning the spans it attached. A span that does not fit the
    /// restored text — out of range, out of order, overlapping, or off a
    /// grapheme boundary — is dropped rather than trusted, so a stale snapshot
    /// can never produce a split label or a caret inside one. The host compares
    /// what it asked for with what it got.
    pub fn restore(&mut self, text: String, spans: &[WireElement]) -> Vec<WireElement> {
        self.set(text);
        let boundaries = self.boundaries();
        let mut limit = 0;
        for &(id, start, end) in spans {
            let fits = start >= limit
                && start < end
                && end <= self.draft.text.len()
                && boundaries.binary_search(&start).is_ok()
                && boundaries.binary_search(&end).is_ok();
            if fits {
                self.elements.push(Element { id, start, end });
                limit = end;
            }
        }
        self.elements()
    }

    /// Inserts `prefix` and then `label` as one atomic element after it
    /// (one undo step). The host's `id` identifies the retained payload.
    pub fn insert_element(&mut self, prefix: &str, label: &str, id: u64) {
        if label.is_empty() {
            return;
        }
        let cursor = self.draft.cursor;
        let (start, _end) = self.replace(cursor, cursor, &format!("{prefix}{label}"));
        // The inserted text starts where the replacement actually landed, which
        // is after the caret when the caret sat inside a label.
        let start = start + prefix.len();
        self.elements.push(Element {
            id,
            start,
            end: start + label.len(),
        });
        self.elements.sort_unstable_by_key(|element| element.start);
    }

    /// Every byte offset an edit may land on: the start of each grapheme plus
    /// the end of the draft.
    fn boundaries(&self) -> Vec<usize> {
        let mut boundaries: Vec<usize> = glyphs(&self.draft.text).iter().map(|g| g.start).collect();
        boundaries.push(self.draft.text.len());
        boundaries
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            draft: self.draft.clone(),
            elements: self.elements.clone(),
        }
    }

    fn apply(&mut self, snapshot: Snapshot) {
        self.draft = snapshot.draft;
        self.elements = snapshot.elements;
        self.preferred_column = None;
    }

    fn undo_or_redo(&mut self, undo: bool) {
        let snapshot = if undo {
            self.undo.pop_back()
        } else {
            self.redo.pop_back()
        };
        let Some(snapshot) = snapshot else { return };
        let current = Snapshot {
            draft: self.draft.clone(),
            elements: self.elements.clone(),
        };
        self.apply(snapshot);
        remember(if undo { &mut self.redo } else { &mut self.undo }, current);
    }

    /// The label containing `pos` strictly inside its range, if any.
    fn element_containing(&self, pos: usize) -> Option<&Element> {
        self.elements
            .iter()
            .find(|element| element.start < pos && pos < element.end)
    }

    /// Snaps an arbitrary offset to the nearer edge of the label around it.
    fn snap(&self, pos: usize) -> usize {
        match self.element_containing(pos) {
            Some(element) if pos - element.start <= element.end - pos => element.start,
            Some(element) => element.end,
            None => pos,
        }
    }

    fn floor_element(&self, pos: usize) -> usize {
        self.element_containing(pos)
            .map_or(pos, |element| element.start)
    }

    fn ceil_element(&self, pos: usize) -> usize {
        self.element_containing(pos)
            .map_or(pos, |element| element.end)
    }

    /// Widens a replaced range so it can never split a label: a range that
    /// touches one takes it whole, and an insertion inside one lands after it.
    fn expand(&self, start: usize, end: usize) -> (usize, usize) {
        if start == end {
            return match self.element_containing(start) {
                Some(element) => (element.end, element.end),
                None => (start, end),
            };
        }
        let mut start = start;
        let mut end = end;
        for element in &self.elements {
            if element.start < end && start < element.end {
                start = start.min(element.start);
                end = end.max(element.end);
            }
        }
        (start, end)
    }

    fn replace(&mut self, start: usize, end: usize, text: &str) -> (usize, usize) {
        if start == end && text.is_empty() {
            return (start, end);
        }
        let (start, end) = self.expand(start.min(end), start.max(end));
        let previous = self.snapshot();
        remember(&mut self.undo, previous);
        self.redo.clear();
        self.draft.text.replace_range(start..end, text);
        let delta = text.len() as isize - (end - start) as isize;
        self.elements.retain_mut(|element| {
            if start <= element.start && element.end <= end {
                return false;
            }
            if element.start >= end {
                element.start = element.start.saturating_add_signed(delta);
                element.end = element.end.saturating_add_signed(delta);
            }
            true
        });
        let desired = start + text.len();
        // Inserting a combining mark or deleting a separator can merge clusters.
        let boundary = glyphs(&self.draft.text)
            .iter()
            .map(|g| g.start)
            .chain(std::iter::once(self.draft.text.len()))
            .find(|&byte| byte >= desired)
            .unwrap();
        self.draft.cursor = self.ceil_element(boundary);
        self.preferred_column = None;
        (start, end)
    }

    pub fn insert(&mut self, text: &str) {
        self.replace(self.draft.cursor, self.draft.cursor, text);
    }

    pub fn cursor(&self) -> usize {
        self.draft.cursor
    }

    /// Replaces a byte range with `text`, clamping offsets to char boundaries.
    /// The host uses this to swap a composer token (an `@mention`) for its
    /// completion; the caret lands after the inserted text.
    pub fn replace_range(&mut self, start: usize, end: usize, text: &str) {
        let len = self.draft.text.len();
        let mut start = floor_boundary(&self.draft.text, start.min(len));
        let mut end = floor_boundary(&self.draft.text, end.min(len));
        if end < start {
            std::mem::swap(&mut start, &mut end);
        }
        self.replace(start, end, text);
    }

    pub fn rows(&self, width: u16) -> usize {
        layout(self.value(), width).rows
    }

    pub fn key(&mut self, code: &str, modifiers: &[String], width: u16) {
        let ctrl = modifiers.len() == 1 && modifiers[0] == "ctrl";
        let alt = modifiers.len() == 1 && modifiers[0] == "alt";
        let plain = modifiers.is_empty();
        let shift = modifiers.len() == 1 && modifiers[0] == "shift";
        if ctrl && matches!(code, "u" | "r") {
            self.undo_or_redo(code == "u");
            return;
        }
        let action = match (code, ctrl, alt, plain) {
            ("a", true, _, _) => "home",
            ("e", true, _, _) => "end",
            ("b", true, _, _) | ("b", _, true, _) => "word_left",
            ("f", true, _, _) | ("f", _, true, _) => "word_right",
            ("h", true, _, _) => "backspace",
            ("d", true, _, _) => "delete",
            ("w", true, _, _) => "word_backspace",
            (_, _, _, true) => code,
            _ => "",
        };
        let glyphs = glyphs(self.value());
        let cursor = self.draft.cursor;
        // A label counts as one unit: the step before it lands on its start and
        // the step after it on its end, so motion and deletion never split it.
        let previous = self
            .elements
            .iter()
            .find(|element| element.end == cursor)
            .map_or_else(
                || {
                    glyphs
                        .iter()
                        .rev()
                        .find(|g| g.start < cursor)
                        .map_or(0, |g| g.start)
                },
                |element| element.start,
            );
        let next = self
            .elements
            .iter()
            .find(|element| element.start == cursor)
            .map_or_else(
                || {
                    glyphs
                        .iter()
                        .find(|g| g.start >= cursor)
                        .map_or(cursor, |g| g.end)
                },
                |element| element.end,
            );
        match action {
            "left" => self.draft.cursor = self.floor_element(previous),
            "right" => self.draft.cursor = self.ceil_element(next),
            "home" => {
                self.draft.cursor =
                    self.floor_element(self.value()[..cursor].rfind('\n').map_or(0, |p| p + 1))
            }
            "end" => {
                self.draft.cursor = self.ceil_element(
                    self.value()[cursor..]
                        .find('\n')
                        .map_or(self.value().len(), |p| cursor + p),
                )
            }
            "word_left" => {
                self.draft.cursor = self.floor_element(previous_word_start(&glyphs, cursor))
            }
            "word_right" => self.draft.cursor = self.ceil_element(next_word_end(&glyphs, cursor)),
            "backspace" => {
                self.replace(self.floor_element(previous), cursor, "");
                return;
            }
            "delete" => {
                self.replace(cursor, self.ceil_element(next), "");
                return;
            }
            "word_backspace" => {
                self.replace(
                    self.floor_element(previous_word_start(&glyphs, cursor)),
                    cursor,
                    "",
                );
                return;
            }
            "up" | "down" => {
                let layout = layout(self.value(), width);
                let current = layout.stops.iter().find(|s| s.byte == cursor).unwrap();
                let col = self.preferred_column.unwrap_or(current.col);
                let row = if action == "up" {
                    current.row.saturating_sub(1)
                } else {
                    (current.row + 1).min(layout.rows - 1)
                };
                let target = layout
                    .stops
                    .iter()
                    .filter(|s| s.row == row)
                    .min_by_key(|s| s.col.abs_diff(col))
                    .unwrap();
                self.draft.cursor = self.snap(target.byte);
                self.preferred_column = Some(col);
                return;
            }
            "enter" => {
                self.insert("\n");
                return;
            }
            _ => {
                if (plain || shift) && code.chars().count() == 1 && !code.contains(char::is_control)
                {
                    self.insert(code);
                }
                return;
            }
        }
        self.preferred_column = None;
    }

    pub fn render(
        &mut self,
        area: Rect,
        buffer: &mut Buffer,
        placeholder: &str,
        focused: bool,
        element_style: Style,
    ) {
        if area.is_empty() {
            return;
        }
        let layout = layout(self.value(), area.width);
        let cursor = layout
            .stops
            .iter()
            .find(|s| s.byte == self.draft.cursor)
            .unwrap();
        let height = usize::from(area.height);
        let scroll = self
            .scroll
            .min(layout.rows.saturating_sub(height))
            .min(cursor.row)
            .max(cursor.row.saturating_sub(height - 1));
        let cursor_row = cursor.row;
        let cursor_col = cursor.col;
        for (g, row, col) in &layout.glyphs {
            if *row >= scroll && *row < scroll + height {
                // A two-cell glyph cannot fit in a one-cell terminal. Paint a
                // replacement, but keep its complete source and edit boundary.
                let symbol = if g.width == 0 || g.width > usize::from(area.width) {
                    "�"
                } else {
                    g.symbol
                };
                // Labels carry the paste style, so a collapsed paste reads as
                // one token rather than as prose the model wrote.
                let style = if self
                    .elements
                    .iter()
                    .any(|element| element.start <= g.start && g.start < element.end)
                {
                    element_style
                } else {
                    Style::new()
                };
                buffer.set_string(
                    area.x + *col as u16,
                    area.y + (*row - scroll) as u16,
                    symbol,
                    style,
                );
            }
        }
        if self.value().is_empty() {
            // Placeholder is display-only; the Elixir boundary sanitizes it.
            buffer.set_stringn(
                area.x,
                area.y,
                placeholder,
                usize::from(area.width),
                Style::new().fg(Color::DarkGray),
            );
        }
        if focused {
            buffer[(
                area.x + cursor_col as u16,
                area.y + (cursor_row - scroll) as u16,
            )]
                .set_style(Style::new().add_modifier(Modifier::REVERSED));
        }
        self.scroll = scroll;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(input: &mut Input, code: &str, width: u16) {
        input.key(code, &[], width);
    }

    #[test]
    fn wraps_with_an_insertion_row_and_preserves_whitespace() {
        assert_eq!(layout("abcd", 4).rows, 2);
        assert_eq!(layout("abcd\n", 4).rows, 3);
        let mut input = Input::default();
        input.insert("ab  cd");
        assert_eq!(input.rows(4), 2);
        assert_eq!(input.value(), "ab  cd");
        key(&mut input, "up", 4);
        assert_eq!(input.draft.cursor, 2);
        key(&mut input, "down", 4);
        assert_eq!(input.draft.cursor, 6);
    }

    #[test]
    fn edits_whole_graphemes_and_normalizes_merged_boundaries() {
        let mut input = Input::default();
        input.insert("界e\u{301}👩‍💻");
        key(&mut input, "backspace", 10);
        assert_eq!(input.value(), "界e\u{301}");
        key(&mut input, "left", 10);
        key(&mut input, "delete", 10);
        assert_eq!(input.value(), "界");
        input.set("a\n\u{301}".into());
        key(&mut input, "home", 10);
        key(&mut input, "backspace", 10);
        assert_eq!(input.value(), "a\u{301}");
        assert_eq!(input.draft.cursor, input.value().len());
    }

    #[test]
    fn paste_is_atomic_and_replacement_resets_history() {
        let mut input = Input::default();
        input.insert("one\ntwo");
        input.key("u", &["ctrl".into()], 10);
        assert_eq!(input.value(), "");
        input.key("r", &["ctrl".into()], 10);
        assert_eq!(input.value(), "one\ntwo");
        input.set("".into());
        input.key("u", &["ctrl".into()], 10);
        assert_eq!(input.value(), "");
    }

    #[test]
    fn an_element_moves_and_deletes_as_one_unit() {
        let mut input = Input::default();
        input.insert("see ");
        input.insert_element(" ", "[P 1]", 7);
        input.insert(" now");
        assert_eq!(input.value(), "see  [P 1] now");
        assert_eq!(input.elements(), vec![(7, 5, 10)]);

        // Motion steps over the whole label in both directions.
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 13);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 12);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 11);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 10);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 5);
        key(&mut input, "right", 80);
        assert_eq!(input.draft.cursor, 10);
        key(&mut input, "right", 80);
        assert_eq!(input.draft.cursor, 11);

        // Word motion stops at the label's own words, so it is snapped out of
        // the range rather than left inside it.
        input.key("b", &["alt".into()], 80);
        assert_eq!(input.draft.cursor, 5);

        // Backspace from just after the label removes it whole and drops its id.
        input.set("".into());
        input.insert("see ");
        input.insert_element("", "[P1]", 3);
        assert_eq!(input.value(), "see [P1]");
        key(&mut input, "backspace", 80);
        assert_eq!(input.value(), "see ");
        assert!(input.elements().is_empty());

        // Undo brings back both the label text and its identity, so Delete from
        // before it can remove the whole thing too.
        input.key("u", &["ctrl".into()], 80);
        assert_eq!(input.value(), "see [P1]");
        assert_eq!(input.elements(), vec![(3, 4, 8)]);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 4);
        key(&mut input, "delete", 80);
        assert_eq!(input.value(), "see ");
        assert!(input.elements().is_empty());
    }

    #[test]
    fn editing_across_an_element_removes_it_whole() {
        let mut input = Input::default();
        input.restore("keep [Image #1] this".into(), &[(1, 5, 15)]);
        assert_eq!(input.elements(), vec![(1, 5, 15)]);

        // A host range that touches only part of the label takes all of it,
        // and a later label is not dragged along.
        input.restore("[one] middle [two]".into(), &[(1, 0, 5), (2, 13, 18)]);
        input.replace_range(3, 5, "X");
        assert_eq!(input.value(), "X middle [two]");
        assert_eq!(input.elements(), vec![(2, 9, 14)]);

        // Typing with the caret inside a label is impossible, so an insert at
        // the caret always lands outside it.
        input.restore("a [Image #1] b".into(), &[(1, 2, 12)]);
        key(&mut input, "left", 80);
        key(&mut input, "left", 80);
        assert_eq!(input.draft.cursor, 12);
        input.insert_element(" ", "[Image #2]", 2);
        assert_eq!(input.value(), "a [Image #1] [Image #2] b");
        assert_eq!(input.elements(), vec![(1, 2, 12), (2, 13, 23)]);
    }

    #[test]
    fn restore_ignores_spans_that_do_not_fit_the_text() {
        let mut input = Input::default();
        let attached = input.restore(
            "[one] x [two]".into(),
            &[
                (1, 0, 5),
                (2, 3, 8), // overlaps the previous span
                (3, 6, 6), // empty
                (4, 6, 99),
                (5, 8, 13),
            ],
        );
        assert_eq!(input.value(), "[one] x [two]");
        assert_eq!(input.elements(), vec![(1, 0, 5), (5, 8, 13)]);
        assert_eq!(attached, vec![(1, 0, 5), (5, 8, 13)]);

        // An edge inside a grapheme is not a place an element may begin or end,
        // so it is dropped too: the caret and the paint both work in graphemes.
        let attached = input.restore("e\u{301}x".into(), &[(6, 0, 2), (7, 0, 3)]);
        assert_eq!(input.value(), "e\u{301}x");
        assert_eq!(attached, vec![(7, 0, 3)]);
        assert_eq!(input.elements(), vec![(7, 0, 3)]);

        // Restoring clears the previous draft's elements rather than merging.
        assert!(input.restore("[one]".into(), &[]).is_empty());
        assert!(input.elements().is_empty());
    }

    #[test]
    fn paint_styles_only_the_label() {
        let mut input = Input::default();
        input.set("a [Image #1]".into());
        input.restore("a [Image #1]".into(), &[(1, 2, 12)]);
        let area = Rect::new(0, 0, 20, 1);
        let mut buffer = Buffer::empty(area);
        input.render(area, &mut buffer, "", false, Style::new().fg(Color::Cyan));
        assert_eq!(buffer[(0, 0)].fg, Color::Reset);
        assert_eq!(buffer[(2, 0)].fg, Color::Cyan);
        assert_eq!(buffer[(11, 0)].fg, Color::Cyan);
        assert_eq!(buffer[(12, 0)].fg, Color::Reset);
    }

    #[test]
    fn cursor_and_paint_agree_across_unicode_edits_and_resizes() {
        let samples = [
            "",
            "a\n\n",
            "abcd\n",
            "界界",
            "a界b",
            "e\u{301}👩‍💻",
            "\u{301}\t\x1b",
        ];
        for text in samples {
            for width in 1..6 {
                let mut input = Input::default();
                input.set(text.into());
                for code in [
                    "up",
                    "up",
                    "down",
                    "left",
                    "right",
                    "home",
                    "end",
                    "backspace",
                    "delete",
                ] {
                    key(&mut input, code, width);
                    let layout = layout(input.value(), width);
                    let cursor = layout
                        .stops
                        .iter()
                        .find(|s| s.byte == input.draft.cursor)
                        .unwrap();
                    assert!(cursor.col < usize::from(width));
                    for row in 0..layout.rows {
                        assert!(layout.stops.iter().any(|s| s.row == row));
                    }
                    let area = Rect::new(0, 0, width, 2);
                    let mut buffer = Buffer::empty(area);
                    input.render(area, &mut buffer, "", true, Style::new());
                    assert!(crate::surface::lines(&buffer).is_ok());
                }
            }
        }
    }

    #[test]
    fn emacs_chords_move_by_whitespace_delimited_words() {
        let mut input = Input::default();
        input.set("  alpha  βe\u{301}ta\nlast  ".into());

        input.key("b", &["alt".into()], 40);
        assert_eq!(&input.value()[input.draft.cursor..], "last  ");
        input.key("b", &["ctrl".into()], 40);
        assert_eq!(&input.value()[input.draft.cursor..], "βe\u{301}ta\nlast  ");

        input.key("f", &["alt".into()], 40);
        assert_eq!(&input.value()[input.draft.cursor..], "\nlast  ");
        input.key("f", &["ctrl".into()], 40);
        assert_eq!(&input.value()[input.draft.cursor..], "  ");
        input.key("f", &["ctrl".into()], 40);
        assert_eq!(input.draft.cursor, input.value().len());

        input.set("word".into());
        input.key("a", &["ctrl".into()], 40);
        input.key("b", &["ctrl".into()], 40);
        assert_eq!(input.draft.cursor, 0);
        input.key("f", &["ctrl".into()], 40);
        input.key("f", &["ctrl".into()], 40);
        assert_eq!(input.draft.cursor, input.value().len());
    }

    #[test]
    fn vertical_motion_retains_column_across_short_rows() {
        let mut input = Input::default();
        input.set("abcd\nx\nabcd".into());
        key(&mut input, "up", 10);
        assert_eq!(input.draft.cursor, 6);
        key(&mut input, "up", 10);
        assert_eq!(input.draft.cursor, 4);
        key(&mut input, "down", 10);
        key(&mut input, "down", 10);
        assert_eq!(input.draft.cursor, 11);
    }

    #[test]
    fn history_is_bounded_and_new_edits_discard_redo() {
        let mut input = Input::default();
        for _ in 0..120 {
            input.insert("x");
        }
        assert_eq!(input.undo.len(), 100);
        input.key("u", &["ctrl".into()], 10);
        input.insert("y");
        assert!(input.redo.is_empty());
        let mut history = VecDeque::new();
        remember(
            &mut history,
            Snapshot {
                draft: Draft {
                    text: "x".repeat(8 * 1024 * 1024 + 1),
                    cursor: 0,
                },
                elements: vec![],
            },
        );
        assert!(history.is_empty());
    }

    #[test]
    fn tiny_viewports_controls_and_scrolling_are_safe() {
        let mut input = Input::default();
        input.insert("界\t\x1b[31m\nend");
        for width in 0..5 {
            for height in 0..4 {
                let area = Rect::new(0, 0, width, height);
                let mut buffer = Buffer::empty(area);
                input.render(area, &mut buffer, "", true, Style::new());
                assert!(crate::surface::lines(&buffer).is_ok());
            }
        }
        assert_eq!(input.value(), "界\t\x1b[31m\nend");
    }
}
