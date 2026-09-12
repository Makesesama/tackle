//! Tackle's editor core. The host owns submission and shortcut precedence.
//! Byte offsets always fall on grapheme boundaries; one layout drives measure,
//! vertical movement, scrolling and paint (including the final insertion cell).
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

#[derive(Default)]
pub struct Input {
    draft: Draft,
    undo: VecDeque<Draft>,
    redo: VecDeque<Draft>,
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
// remains editable, but does not force an unbounded undo archive.
fn remember(history: &mut VecDeque<Draft>, draft: Draft) {
    const BUDGET: usize = 8 * 1024 * 1024;
    history.push_back(draft);
    let mut bytes: usize = history.iter().map(|d| d.text.len()).sum();
    while history.len() > 100 || bytes > BUDGET {
        bytes -= history.pop_front().unwrap().text.len();
    }
}

impl Input {
    pub fn value(&self) -> &str {
        &self.draft.text
    }

    pub fn set(&mut self, text: String) {
        self.draft = Draft {
            cursor: text.len(),
            text,
        };
        self.undo.clear();
        self.redo.clear();
        self.preferred_column = None;
        self.scroll = 0;
    }

    fn replace(&mut self, start: usize, end: usize, text: &str) {
        if start == end && text.is_empty() {
            return;
        }
        remember(&mut self.undo, self.draft.clone());
        self.redo.clear();
        self.draft.text.replace_range(start..end, text);
        let desired = start + text.len();
        // Inserting a combining mark or deleting a separator can merge clusters.
        self.draft.cursor = glyphs(&self.draft.text)
            .iter()
            .map(|g| g.start)
            .chain(std::iter::once(self.draft.text.len()))
            .find(|&byte| byte >= desired)
            .unwrap();
        self.preferred_column = None;
    }

    pub fn insert(&mut self, text: &str) {
        self.replace(self.draft.cursor, self.draft.cursor, text);
    }

    pub fn rows(&self, width: u16) -> usize {
        layout(self.value(), width).rows
    }

    pub fn key(&mut self, code: &str, modifiers: &[String], width: u16) {
        let ctrl = modifiers.len() == 1 && modifiers[0] == "ctrl";
        let plain = modifiers.is_empty();
        let shift = modifiers.len() == 1 && modifiers[0] == "shift";
        if ctrl && matches!(code, "u" | "r") {
            let (from, to) = if code == "u" {
                (&mut self.undo, &mut self.redo)
            } else {
                (&mut self.redo, &mut self.undo)
            };
            if let Some(draft) = from.pop_back() {
                remember(to, std::mem::replace(&mut self.draft, draft));
                self.preferred_column = None;
            }
            return;
        }
        let action = match (code, ctrl, plain) {
            ("a", true, _) => "home",
            ("e", true, _) => "end",
            ("b", true, _) => "left",
            ("f", true, _) => "right",
            ("h", true, _) => "backspace",
            ("d", true, _) => "delete",
            ("w", true, _) => "word_backspace",
            (_, _, true) => code,
            _ => "",
        };
        let glyphs = glyphs(self.value());
        let cursor = self.draft.cursor;
        let previous = glyphs
            .iter()
            .rev()
            .find(|g| g.start < cursor)
            .map_or(0, |g| g.start);
        let next = glyphs
            .iter()
            .find(|g| g.start >= cursor)
            .map_or(cursor, |g| g.end);
        match action {
            "left" => self.draft.cursor = previous,
            "right" => self.draft.cursor = next,
            "home" => self.draft.cursor = self.value()[..cursor].rfind('\n').map_or(0, |p| p + 1),
            "end" => {
                self.draft.cursor = self.value()[cursor..]
                    .find('\n')
                    .map_or(self.value().len(), |p| cursor + p)
            }
            "backspace" => {
                self.replace(previous, cursor, "");
                return;
            }
            "delete" => {
                self.replace(cursor, next, "");
                return;
            }
            "word_backspace" => {
                let mut start = cursor;
                let mut seen_word = false;
                for g in glyphs.iter().rev().filter(|g| g.start < cursor) {
                    let space = g.symbol.chars().all(char::is_whitespace);
                    if seen_word && space {
                        break;
                    }
                    seen_word |= !space;
                    start = g.start;
                }
                self.replace(start, cursor, "");
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
                self.draft.cursor = target.byte;
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

    pub fn render(&mut self, area: Rect, buffer: &mut Buffer, placeholder: &str, focused: bool) {
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
                buffer.set_string(
                    area.x + *col as u16,
                    area.y + (*row - scroll) as u16,
                    symbol,
                    Style::new(),
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
                    input.render(area, &mut buffer, "", true);
                    assert!(crate::surface::lines(&buffer).is_ok());
                }
            }
        }
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
            Draft {
                text: "x".repeat(8 * 1024 * 1024 + 1),
                cursor: 0,
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
                input.render(area, &mut buffer, "", true);
                assert!(crate::surface::lines(&buffer).is_ok());
            }
        }
        assert_eq!(input.value(), "界\t\x1b[31m\nend");
    }
}
