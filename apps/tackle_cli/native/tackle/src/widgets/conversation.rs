//! Immutable history cells and a viewport over them. Like Codex's history cells,
//! settled cells cache width-dependent layout; replacing the live tail does not
//! parse or lay out settled Markdown again. No session or provider state lives here.
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::Style,
    text::{Line, Span, Text},
    widgets::{Paragraph, Widget, Wrap},
};
use std::sync::Arc;

pub struct HistoryCell {
    width: u16,
    lines: Vec<MeasuredLine>,
    height: usize,
    style: Style,
    gutter: u16,
    right_padding: u16,
    marker: Option<Span<'static>>,
}

struct MeasuredLine {
    line: Line<'static>,
    top: usize,
    height: usize,
    wrap: bool,
}

impl HistoryCell {
    pub fn markdown(source: &str, width: u16, style: Style) -> Self {
        Self::new(
            tui_markdown::from_str(&sanitize(source)),
            width,
            style,
            true,
        )
    }

    /// A message has a hanging gutter, not a prefix inside its wrapped text.
    /// On tiny terminals chrome yields to at least one column of content.
    pub fn message(
        source: &str,
        width: u16,
        markdown: bool,
        style: Style,
        marker: Span<'static>,
    ) -> Self {
        let width = width.max(1);
        let gutter = if width >= 4 { 2 } else { 0 };
        let right_padding = if width >= 4 { 1 } else { 0 };
        let source = sanitize(source);
        let text = if markdown {
            tui_markdown::from_str(&source)
        } else {
            Text::from(source.split('\n').map(Line::from).collect::<Vec<_>>())
        };
        let mut cell = Self::new(text, width - gutter - right_padding, style, markdown);
        // Plain prompts preserve indentation and explicit newlines, but still
        // wrap by grapheme instead of clipping at the content edge.
        if !markdown {
            let rows: Vec<_> = cell
                .lines
                .into_iter()
                .flat_map(|line| grapheme_wrap(line.line, width - gutter - right_padding))
                .collect();
            cell = Self::new(
                Text::from(rows),
                width - gutter - right_padding,
                style,
                false,
            );
        }
        cell.width = width;
        cell.gutter = gutter;
        cell.right_padding = right_padding;
        cell.marker = Some(marker);
        cell
    }

    /// Plain diagnostic text retains indentation and wraps by grapheme without
    /// imposing Markdown interpretation or a message gutter.
    pub fn plain(source: &str, width: u16, style: Style) -> Self {
        let source = sanitize(source);
        let lines: Vec<_> = source
            .split('\n')
            .flat_map(|line| grapheme_wrap(Line::from(line.to_owned()), width.max(1)))
            .collect();
        Self::new(Text::from(lines), width, style, false)
    }

    pub fn rows(lines: Vec<Line<'static>>, width: u16) -> Self {
        Self::new(Text::from(lines), width, Style::default(), false)
    }

    /// Highlighted code shares the message gutter but wraps by grapheme,
    /// preserving indentation and token styles rather than trimming prose words.
    pub fn code(
        lines: Vec<Line<'static>>,
        width: u16,
        style: Style,
        marker: Option<Span<'static>>,
    ) -> Self {
        let width = width.max(1);
        let gutter = if width >= 4 { 2 } else { 0 };
        let right_padding = if width >= 4 { 1 } else { 0 };
        let content_width = width - gutter - right_padding;
        let lines: Vec<_> = lines
            .into_iter()
            .flat_map(|line| grapheme_wrap(line, content_width))
            .collect();
        let mut cell = Self::new(Text::from(lines), content_width, style, false);
        cell.width = width;
        cell.gutter = gutter;
        cell.right_padding = right_padding;
        cell.marker = marker;
        cell
    }

    fn new(text: Text<'_>, width: u16, style: Style, wrap: bool) -> Self {
        let width = width.max(1);
        let mut lines = Vec::new();
        let mut top = 0;
        for line in text.lines {
            let line = Line::from(
                line.spans
                    .into_iter()
                    .map(|span| Span::styled(sanitize(&span.content), span.style))
                    .collect::<Vec<_>>(),
            )
            .style(text.style.patch(line.style));
            let height = if wrap {
                Paragraph::new(line.clone())
                    .wrap(Wrap { trim: true })
                    .line_count(width)
            } else {
                1
            };
            // Paragraph's scroll field is u16, not a transcript-wide row index.
            // Exceptionally long logical lines use grapheme wrapping; ordinary
            // Markdown keeps Ratatui's word wrapping and complete parser context.
            if height > usize::from(u16::MAX) {
                for part in grapheme_wrap(line, width) {
                    lines.push(MeasuredLine {
                        line: part,
                        top,
                        height: 1,
                        wrap: false,
                    });
                    top += 1;
                }
            } else {
                lines.push(MeasuredLine {
                    line,
                    top,
                    height,
                    wrap,
                });
                top += height;
            }
        }
        Self {
            width,
            lines,
            height: top,
            style,
            gutter: 0,
            right_padding: 0,
            marker: None,
        }
    }

    pub fn height(&self) -> usize {
        self.height
    }
    pub fn width(&self) -> u16 {
        self.width
    }

    fn render(&self, offset: usize, area: Rect, buffer: &mut Buffer) {
        buffer.set_style(area, self.style);
        if offset == 0 && self.gutter > 0 {
            if let Some(marker) = &self.marker {
                Line::from(marker.clone())
                    .render(Rect::new(area.x, area.y, self.gutter, 1), buffer);
            }
        }
        let area = Rect::new(
            area.x + self.gutter,
            area.y,
            area.width.saturating_sub(self.gutter + self.right_padding),
            area.height,
        );
        let first = self
            .lines
            .partition_point(|line| line.top + line.height <= offset);
        for line in &self.lines[first..] {
            let skip = offset.saturating_sub(line.top);
            let y = line.top.saturating_sub(offset);
            if y >= usize::from(area.height) {
                break;
            }
            let height = (line.height - skip).min(usize::from(area.height) - y) as u16;
            let rect = Rect::new(area.x, area.y + y as u16, area.width, height);
            let base = if line.wrap {
                self.style
            } else {
                self.style.patch(line.line.style)
            };
            let mut paragraph = Paragraph::new(line.line.clone())
                .style(base)
                .scroll((skip as u16, 0));
            if line.wrap {
                paragraph = paragraph.wrap(Wrap { trim: true });
            }
            paragraph.render(rect, buffer);
        }
    }
}

pub struct Conversation {
    cells: Vec<Arc<HistoryCell>>,
    tops: Vec<usize>,
    pub height: usize,
}

impl Conversation {
    pub fn new(cells: Vec<Arc<HistoryCell>>) -> Self {
        let mut height = 0;
        let tops = cells
            .iter()
            .map(|cell| {
                let top = height;
                height += cell.height();
                top
            })
            .collect();
        Self {
            cells,
            tops,
            height,
        }
    }

    pub fn widget(
        &self,
        offset: usize,
        selected: &[usize],
        selection: Style,
    ) -> ConversationWidget<'_> {
        ConversationWidget {
            conversation: self,
            offset,
            selected: selected.to_vec(),
            selection,
        }
    }
}

pub struct ConversationWidget<'a> {
    conversation: &'a Conversation,
    offset: usize,
    selected: Vec<usize>,
    selection: Style,
}

impl Widget for ConversationWidget<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        if area.is_empty() {
            return;
        }
        let conversation = self.conversation;
        let first = conversation
            .tops
            .partition_point(|top| *top <= self.offset)
            .saturating_sub(1);
        for index in first..conversation.cells.len() {
            let cell = &conversation.cells[index];
            let top = conversation.tops[index];
            let skip = self.offset.saturating_sub(top);
            if skip >= cell.height() {
                continue;
            }
            let y = top.saturating_sub(self.offset);
            if y >= usize::from(area.height) {
                break;
            }
            let height = (cell.height() - skip).min(usize::from(area.height) - y) as u16;
            let rect = Rect::new(area.x, area.y + y as u16, area.width, height);
            cell.render(skip, rect, buffer);
            // Selection overrides even syntax/diff span backgrounds, not their
            // foreground colors. The full width remains visibly selected.
            if self.selected.contains(&index) {
                buffer.set_style(rect, self.selection);
            }
        }
    }
}

fn grapheme_wrap(line: Line<'static>, width: u16) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let mut spans = Vec::new();
    let mut used = 0;
    for grapheme in line.styled_graphemes(Style::default()) {
        let size = Span::raw(grapheme.symbol).width();
        if used + size > usize::from(width) && !spans.is_empty() {
            lines.push(Line::from(std::mem::take(&mut spans)).style(line.style));
            used = 0;
        }
        let symbol = if size > usize::from(width) {
            "�"
        } else {
            grapheme.symbol
        };
        spans.push(Span::styled(symbol.to_owned(), grapheme.style));
        used += Span::raw(symbol).width();
    }
    lines.push(Line::from(spans).style(line.style));
    lines
}

// Native callers cannot bypass the paint boundary. Keep source in Elixir for
// explicit copy/search; CSI, OSC, DCS and C1 controls never reach a terminal.
pub fn sanitize(source: &str) -> String {
    enum Mode {
        Text,
        Escape,
        Csi,
        String,
        StringEscape,
    }
    let mut mode = Mode::Text;
    let mut result = String::new();
    for c in source.chars() {
        mode = match mode {
            Mode::Text => match c {
                '\u{1b}' => Mode::Escape,
                '\u{9b}' => Mode::Csi,
                '\u{90}' | '\u{9d}' | '\u{9e}' | '\u{9f}' => Mode::String,
                '\n' => {
                    result.push(c);
                    Mode::Text
                }
                '\t' => {
                    result.push_str("  ");
                    Mode::Text
                }
                c if c.is_control() => Mode::Text,
                c => {
                    result.push(c);
                    Mode::Text
                }
            },
            Mode::Escape => match c {
                '[' => Mode::Csi,
                ']' | 'P' | '^' | '_' => Mode::String,
                _ => Mode::Text,
            },
            Mode::Csi => {
                if ('\u{40}'..='\u{7e}').contains(&c) {
                    Mode::Text
                } else {
                    Mode::Csi
                }
            }
            Mode::String => match c {
                '\u{7}' | '\u{9c}' => Mode::Text,
                '\u{1b}' => Mode::StringEscape,
                _ => Mode::String,
            },
            Mode::StringEscape => {
                if c == '\\' {
                    Mode::Text
                } else {
                    Mode::String
                }
            }
        };
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::{Color, Modifier};

    fn paint(conversation: &Conversation, width: u16, height: u16, offset: usize) -> Buffer {
        let area = Rect::new(2, 3, width, height);
        let mut buffer = Buffer::empty(area);
        conversation
            .widget(offset, &[], Style::default())
            .render(area, &mut buffer);
        buffer
    }

    fn text(buffer: &Buffer) -> String {
        buffer.content.iter().map(|cell| cell.symbol()).collect()
    }

    #[test]
    fn markdown_measurement_and_every_clipped_window_match_ratatui() {
        let sources = [
            "# Heading\n\nSome **bold** and *italic* text.\n\n- first\n- second",
            "```elixir\nIO.puts(\"incomplete fence\")",
            "> quote\n\n  whitespace  \n\n界e\u{301} ❤️",
            "123456 123456 123456\n\nlast",
        ];
        for source in sources {
            for width in [1, 8, 20, 80] {
                let cell = Arc::new(HistoryCell::markdown(source, width, Style::default()));
                let paragraph =
                    Paragraph::new(tui_markdown::from_str(source)).wrap(Wrap { trim: true });
                assert_eq!(cell.height(), paragraph.line_count(width));
                let conversation = Conversation::new(vec![cell]);
                for offset in 0..=conversation.height {
                    let actual = paint(&conversation, width, 3, offset);
                    let mut expected = Buffer::empty(actual.area);
                    paragraph
                        .clone()
                        .scroll((offset as u16, 0))
                        .render(expected.area, &mut expected);
                    assert_eq!(
                        actual, expected,
                        "width={width}, offset={offset}, source={source}"
                    );
                }
            }
        }
    }

    #[test]
    fn scroll_is_not_limited_to_u16_and_does_not_discard_markdown_styles() {
        let source = (0..70_000)
            .map(|i| format!("**row {i}**  \n"))
            .collect::<String>();
        let cell = Arc::new(HistoryCell::markdown(&source, 20, Style::default()));
        let conversation = Conversation::new(vec![cell]);
        assert_eq!(conversation.height, 70_000);
        let buffer = paint(&conversation, 20, 2, 69_999);
        assert!(text(&buffer).contains("row 69999"));
        assert!(buffer[(2, 3)].modifier.contains(Modifier::BOLD));
        assert!(text(&paint(&conversation, 20, 2, usize::MAX))
            .trim()
            .is_empty());
    }

    #[test]
    fn exceptionally_long_logical_line_has_a_renderable_tail() {
        let source = format!("**{}Z**", "x".repeat(65_536));
        let conversation = Conversation::new(vec![Arc::new(HistoryCell::markdown(
            &source,
            1,
            Style::default(),
        ))]);
        assert_eq!(conversation.height, 65_537);
        let buffer = paint(&conversation, 1, 1, 65_536);
        assert_eq!(text(&buffer), "Z");
        assert!(buffer[(2, 3)].modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn rows_keep_surface_and_selection_overrides_span_backgrounds() {
        let line = Line::from(Span::styled(
            "界e\u{301}",
            Style::default().fg(Color::Green).bg(Color::Red),
        ))
        .style(Style::default().bg(Color::Blue));
        let cell = Arc::new(HistoryCell::rows(vec![line], 8));
        let conversation = Conversation::new(vec![cell]);
        let mut buffer = paint(&conversation, 8, 1, 0);
        assert_eq!(buffer[(9, 3)].bg, Color::Blue);
        conversation
            .widget(0, &[0], Style::default().bg(Color::Cyan))
            .render(buffer.area, &mut buffer);
        assert!(buffer.content.iter().all(|cell| cell.bg == Color::Cyan));
        assert_eq!(buffer[(2, 3)].fg, Color::Green);
        assert!(crate::surface::lines(&buffer).is_ok());
    }

    #[test]
    fn empty_cells_and_zero_rectangles_are_safe() {
        let empty = Arc::new(HistoryCell::markdown("", 10, Style::default()));
        let body = Arc::new(HistoryCell::markdown("body", 10, Style::default()));
        let conversation = Conversation::new(vec![empty.clone(), body, empty]);
        assert!(text(&paint(&conversation, 10, 1, 0)).contains("body"));
        assert!(text(&paint(&conversation, 10, 1, 1)).trim().is_empty());
        assert!(paint(&conversation, 0, 0, 0).content.is_empty());
    }

    #[test]
    fn message_gutters_survive_wrapping_and_clipping_without_repeating_markers() {
        for markdown in [false, true] {
            for width in [1, 3, 4, 12, 40] {
                let style = Style::default().bg(Color::Indexed(236));
                let cell = Arc::new(HistoryCell::message(
                    "alpha beta gamma\n\n  indented 界e\u{301}",
                    width,
                    markdown,
                    style,
                    Span::styled("●", Style::default().fg(Color::Cyan)),
                ));
                let conversation = Conversation::new(vec![cell]);
                let full = paint(&conversation, width, conversation.height as u16, 0);
                assert!(full
                    .content
                    .iter()
                    .all(|cell| cell.bg == Color::Indexed(236)));
                for offset in 0..conversation.height {
                    let clipped = paint(&conversation, width, 1, offset);
                    for x in 0..width {
                        assert_eq!(clipped[(2 + x, 3)], full[(2 + x, 3 + offset as u16)]);
                    }
                    if width >= 4 {
                        assert_eq!(
                            clipped[(2, 3)].symbol(),
                            if offset == 0 { "●" } else { " " }
                        );
                        assert_eq!(clipped[(3, 3)].symbol(), " ");
                        assert_eq!(clipped[(width + 1, 3)].symbol(), " ");
                    }
                }
                let mut selected = paint(&conversation, width, 1, 0);
                conversation
                    .widget(0, &[0], Style::default().bg(Color::Blue))
                    .render(selected.area, &mut selected);
                assert!(selected.content.iter().all(|cell| cell.bg == Color::Blue));
            }
        }
    }

    #[test]
    fn plain_messages_preserve_indentation_and_do_not_parse_markdown() {
        let conversation = Conversation::new(vec![Arc::new(HistoryCell::message(
            "  **raw**\nnext",
            10,
            false,
            Style::default(),
            Span::raw("›"),
        ))]);
        let buffer = paint(&conversation, 10, 3, 0);
        let rows: Vec<String> = buffer
            .content
            .chunks(10)
            .map(|row| row.iter().map(|cell| cell.symbol()).collect())
            .collect();
        assert_eq!(rows, ["›   **raw ", "  **      ", "  next    "]);
        assert!(!buffer
            .content
            .iter()
            .any(|cell| cell.modifier.contains(Modifier::BOLD)));
    }

    #[test]
    fn strips_terminal_sequences_including_incomplete_streams() {
        assert_eq!(
            sanitize("ok\x1b]52;c;secret\x07\x1b[31mred\x1b[0m\t!"),
            "okred  !"
        );
        assert_eq!(sanitize("ok\x1bPsecret\x1b\\!\u{9b}31mred\u{7f}"), "ok!red");
        assert_eq!(sanitize("ok\x1b]unfinished"), "ok");
    }
}
