//! Viewport-aware re-layout for rendered Markdown tables.
//!
//! `tui-markdown` sizes each column to its widest cell and emits the finished
//! table as box-drawing lines. When such a table is wider than the viewport,
//! the surrounding word wrap breaks the frame mid-border and the table becomes
//! unreadable. This pass finds completed tables in the rendered [`Text`] — a
//! top border, header row, separator, body rows and bottom border whose border
//! spans carry the theme's `table_border` style — and re-renders them to fit
//! the available width: columns shrink proportionally (never below the widest
//! word that fits the budget), cell contents word-wrap inside their column,
//! and rows grow downward instead of the frame growing sideways.
//!
//! Tables that already fit, and lines that are not tables, pass through
//! unchanged. Blockquote and list prefixes are preserved: the first line keeps
//! its own prefix and continuation lines keep the header line's prefix.

use crate::markdown::ThemeMarkdown;
use ratatui::{
    style::Style,
    text::{Line, Span, Text},
};
use std::borrow::Cow;

/// A styled grapheme with its terminal display width.
#[derive(Clone)]
struct Grapheme {
    symbol: String,
    style: Style,
    width: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Alignment {
    Left,
    Center,
    Right,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BorderKind {
    Top,
    Separator,
    Bottom,
}

/// Rewrites rendered Markdown tables so each one fits `width`.
pub(crate) fn fit(text: Text<'_>, width: u16, styles: &ThemeMarkdown) -> Text<'static> {
    let Text {
        lines,
        style,
        alignment,
    } = text;
    let mut out: Vec<Line<'static>> = Vec::with_capacity(lines.len());
    let mut index = 0;
    while index < lines.len() {
        match Table::parse(&lines[index..], styles) {
            Some((table, consumed)) => {
                let fallback = || {
                    (0..consumed)
                        .map(|offset| owned(&lines[index + offset]))
                        .collect::<Vec<_>>()
                };
                out.extend(table.relayout(usize::from(width)).unwrap_or_else(fallback));
                index += consumed;
            }
            None => {
                out.push(owned(&lines[index]));
                index += 1;
            }
        }
    }
    Text {
        lines: out,
        style,
        alignment,
    }
}

/// A parsed table: everything needed to re-render it at a smaller width.
struct Table {
    top_prefix: Vec<Span<'static>>,
    top_style: Style,
    body_prefix: Vec<Span<'static>>,
    body_style: Style,
    border_style: Style,
    header_style: Style,
    cell_style: Style,
    /// Natural column widths, as measured by the original border line.
    columns: Vec<usize>,
    alignments: Vec<Alignment>,
    /// Raw cell spans including their original padding, per row.
    header: Vec<Vec<Span<'static>>>,
    rows: Vec<Vec<Vec<Span<'static>>>>,
}

impl Table {
    /// Recognizes a complete table at the start of `lines`, returning it with
    /// the number of lines it occupies. Any structural or style mismatch
    /// yields `None`, so prose and code art are never rewritten.
    fn parse(lines: &[Line<'_>], styles: &ThemeMarkdown) -> Option<(Table, usize)> {
        let border_style = styles.table_border;
        let (columns, top_prefix) = parse_border(&lines[0], BorderKind::Top, border_style)?;
        let top_style = lines[0].style;
        let (body_prefix, header) = parse_row(&lines[1], border_style, columns.len())?;
        let body_style = lines[1].style;
        if parse_border(&lines[2], BorderKind::Separator, border_style)?.0 != columns {
            return None;
        }
        let mut rows = Vec::new();
        let mut consumed = 3;
        loop {
            let line = lines.get(consumed)?;
            match parse_border(line, BorderKind::Bottom, border_style) {
                Some((cols, _)) if cols == columns => {
                    consumed += 1;
                    break;
                }
                // A border line that is not the matching bottom belongs to
                // some other structure: leave the whole group alone.
                Some(_) => return None,
                None => {}
            }
            let (_, row) = parse_row(line, border_style, columns.len())?;
            rows.push(row);
            consumed += 1;
        }
        let alignments = header
            .iter()
            .zip(&columns)
            .map(|(cell, &width)| infer_alignment(cell, width))
            .collect();
        Some((
            Table {
                top_prefix,
                top_style,
                body_prefix,
                body_style,
                border_style,
                header_style: styles.table_header,
                cell_style: styles.table_cell,
                columns,
                alignments,
                header,
                rows,
            },
            consumed,
        ))
    }

    /// Re-renders the table to fit `width`. Returns `None` when the table
    /// already fits or the width cannot hold the smallest useful frame, in
    /// which case the caller keeps the original lines.
    fn relayout(&self, width: usize) -> Option<Vec<Line<'static>>> {
        let prefix = span_width(&self.top_prefix).max(span_width(&self.body_prefix));
        let available = width.saturating_sub(prefix);
        let count = self.columns.len();
        // Vertical borders plus one space of padding on each side of a cell.
        let frame = count * 3 + 1;
        let natural: usize = self.columns.iter().sum();
        if natural + frame <= available {
            return None;
        }
        let budget = available.saturating_sub(frame);
        if budget < count {
            return None;
        }
        let minimum: Vec<usize> = self
            .columns
            .iter()
            .enumerate()
            .map(|(index, &natural)| {
                let longest = std::iter::once(&self.header)
                    .chain(self.rows.iter())
                    .map(|row| longest_word(&row[index]))
                    .max()
                    .unwrap_or(1);
                longest.min(natural).max(1)
            })
            .collect();
        let widths = allocate(&self.columns, &minimum, budget);
        let header: Vec<_> = self
            .header
            .iter()
            .enumerate()
            .map(|(index, cell)| wrap_cell(cell, widths[index]))
            .collect();
        let rows: Vec<_> = self
            .rows
            .iter()
            .map(|row| {
                row.iter()
                    .enumerate()
                    .map(|(index, cell)| wrap_cell(cell, widths[index]))
                    .collect::<Vec<_>>()
            })
            .collect();
        let mut lines = vec![self.border_line(BorderKind::Top, &widths, true)];
        lines.extend(self.render_row(&header, &widths, self.header_style));
        lines.push(self.border_line(BorderKind::Separator, &widths, false));
        for row in &rows {
            lines.extend(self.render_row(row, &widths, self.cell_style));
        }
        lines.push(self.border_line(BorderKind::Bottom, &widths, false));
        Some(lines)
    }

    /// One border line with the recomputed column widths.
    fn border_line(&self, kind: BorderKind, widths: &[usize], top: bool) -> Line<'static> {
        let (open, join, close) = match kind {
            BorderKind::Top => ('┌', '┬', '┐'),
            BorderKind::Separator => ('├', '┼', '┤'),
            BorderKind::Bottom => ('└', '┴', '┘'),
        };
        let mut content = String::new();
        content.push(open);
        for (index, &width) in widths.iter().enumerate() {
            for _ in 0..width + 2 {
                content.push('─');
            }
            if index + 1 < widths.len() {
                content.push(join);
            }
        }
        content.push(close);
        let mut spans = if top {
            self.top_prefix.clone()
        } else {
            self.body_prefix.clone()
        };
        spans.push(Span::styled(content, self.border_style));
        Line {
            spans,
            style: if top { self.top_style } else { self.body_style },
            alignment: None,
        }
    }

    /// The visual lines of one header or body row, padded and aligned.
    fn render_row(
        &self,
        cells: &[Vec<Vec<Span<'static>>>],
        widths: &[usize],
        style: Style,
    ) -> Vec<Line<'static>> {
        let height = cells.iter().map(|cell| cell.len()).max().unwrap_or(1);
        (0..height)
            .map(|visual| {
                let mut spans = self.body_prefix.clone();
                for (index, &width) in widths.iter().enumerate() {
                    spans.push(Span::styled("│", self.border_style));
                    let content = cells
                        .get(index)
                        .and_then(|cell| cell.get(visual))
                        .map(|spans| spans.as_slice())
                        .unwrap_or(&[]);
                    let content_width = content.iter().map(Span::width).sum();
                    let (left, right) = padding(width, content_width, self.alignments[index]);
                    spans.push(Span::styled(" ".repeat(left + 1), style));
                    spans.extend(content.iter().cloned());
                    spans.push(Span::styled(" ".repeat(right + 1), style));
                }
                spans.push(Span::styled("│", self.border_style));
                Line {
                    spans,
                    style: self.body_style,
                    alignment: None,
                }
            })
            .collect()
    }
}

/// A border line is prefix spans plus exactly one span of box-drawing glyphs.
/// Returns its column widths and the number of prefix spans.
fn parse_border(
    line: &Line<'_>,
    kind: BorderKind,
    border_style: Style,
) -> Option<(Vec<usize>, Vec<Span<'static>>)> {
    let prefix = prefix_len(line)?;
    if line.spans.len() != prefix + 1 {
        return None;
    }
    let span = &line.spans[prefix];
    if span.style != border_style {
        return None;
    }
    let columns = border_columns(&span.content, kind)?;
    Some((columns, owned_spans(&line.spans[..prefix])))
}

/// A row line is prefix spans, then `columns` cells delimited by border spans.
/// Returns the prefix spans and the raw cell spans.
fn parse_row(
    line: &Line<'_>,
    border_style: Style,
    columns: usize,
) -> Option<(Vec<Span<'static>>, Vec<Vec<Span<'static>>>)> {
    let prefix = prefix_len(line)?;
    let spans = &line.spans[prefix..];
    let first = spans.first()?;
    if !is_border(first, border_style) {
        return None;
    }
    let mut cells = Vec::with_capacity(columns);
    let mut cell: Vec<Span<'static>> = Vec::new();
    for span in &spans[1..] {
        if is_border(span, border_style) {
            cells.push(std::mem::take(&mut cell));
            if cells.len() > columns {
                return None;
            }
        } else {
            cell.push(Span {
                content: Cow::Owned(span.content.to_string()),
                style: span.style,
            });
        }
    }
    if !cell.is_empty() || cells.len() != columns {
        return None;
    }
    Some((owned_spans(&line.spans[..prefix]), cells))
}

fn is_border(span: &Span<'_>, border_style: Style) -> bool {
    span.content.as_ref() == "│" && span.style == border_style
}

/// Leading spans that may carry a blockquote or list marker before a table.
fn prefix_len(line: &Line<'_>) -> Option<usize> {
    let mut count = 0;
    for span in &line.spans {
        if span.content.chars().all(is_marker_char) {
            count += 1;
        } else {
            return Some(count);
        }
    }
    Some(count)
}

fn is_marker_char(c: char) -> bool {
    c.is_whitespace() || matches!(c, '>' | '-' | '.' | '(' | ')') || c.is_ascii_digit()
}

/// Parses `┌─…─┬…┐`-style border content into its column widths.
fn border_columns(content: &str, kind: BorderKind) -> Option<Vec<usize>> {
    let (open, join, close) = match kind {
        BorderKind::Top => ('┌', '┬', '┐'),
        BorderKind::Separator => ('├', '┼', '┤'),
        BorderKind::Bottom => ('└', '┴', '┘'),
    };
    let mut chars = content.chars();
    if chars.next() != Some(open) {
        return None;
    }
    let mut columns = Vec::new();
    let mut run = 0;
    let mut closed = false;
    for c in chars {
        if closed {
            return None;
        }
        match c {
            '─' => run += 1,
            c if c == join => {
                columns.push(run);
                run = 0;
            }
            c if c == close => {
                columns.push(run);
                run = 0;
                closed = true;
            }
            _ => return None,
        }
    }
    if closed && !columns.is_empty() {
        Some(columns)
    } else {
        None
    }
}

/// Infers a column's alignment from the header cell's original padding.
fn infer_alignment(cell: &[Span<'_>], column: usize) -> Alignment {
    let graphemes = cell_graphemes(cell);
    let total: usize = graphemes.iter().map(|g| g.width).sum();
    let lead: usize = graphemes
        .iter()
        .take_while(|g| is_space(g))
        .map(|g| g.width)
        .sum();
    let trail: usize = graphemes
        .iter()
        .rev()
        .take_while(|g| is_space(g))
        .map(|g| g.width)
        .sum();
    let content = total.saturating_sub(lead + trail);
    if content == 0 || content >= column {
        return Alignment::Left;
    }
    match (lead.saturating_sub(1), trail.saturating_sub(1)) {
        (0, _) => Alignment::Left,
        (_, 0) => Alignment::Right,
        _ => Alignment::Center,
    }
}

/// Column widths for a table that must fit `budget` total content columns.
///
/// Columns never grow beyond their natural width. When the budget allows,
/// every column keeps at least its longest word so words stay unbroken;
/// otherwise words must break and columns share the budget proportionally.
fn allocate(natural: &[usize], minimum: &[usize], budget: usize) -> Vec<usize> {
    let count = natural.len();
    let min_total: usize = minimum.iter().sum();
    let mut widths: Vec<usize> = if min_total <= budget {
        let extra = budget - min_total;
        let stretch: usize = natural
            .iter()
            .zip(minimum)
            .map(|(&nat, &min)| nat - min)
            .sum();
        natural
            .iter()
            .zip(minimum)
            .map(|(&nat, &min)| {
                let share = (extra * (nat - min)).checked_div(stretch).unwrap_or(0);
                (min + share).clamp(min, nat)
            })
            .collect()
    } else {
        let total: usize = natural.iter().sum();
        natural
            .iter()
            .map(|&nat| (budget * nat / total.max(1)).clamp(1, nat))
            .collect()
    };
    // Repair rounding so the frame fills the available width exactly.
    let mut sum: usize = widths.iter().sum();
    while sum > budget {
        let index = (0..count)
            .max_by_key(|&i| (widths[i], natural[i]))
            .unwrap_or(0);
        let floor = if min_total <= budget {
            minimum[index]
        } else {
            1
        };
        if widths[index] <= floor {
            break;
        }
        widths[index] -= 1;
        sum -= 1;
    }
    while sum < budget {
        let index = (0..count)
            .max_by_key(|&i| (natural[i].saturating_sub(widths[i]), natural[i]))
            .unwrap_or(0);
        if widths[index] >= natural[index] {
            break;
        }
        widths[index] += 1;
        sum += 1;
    }
    widths
}

fn padding(column: usize, content: usize, alignment: Alignment) -> (usize, usize) {
    if content >= column {
        return (0, 0);
    }
    let total = column - content;
    match alignment {
        Alignment::Left => (0, total),
        Alignment::Right => (total, 0),
        Alignment::Center => {
            let left = total / 2;
            (left, total - left)
        }
    }
}

/// Word-wraps a cell's content to `width`, returning one span list per line.
fn wrap_cell(cell: &[Span<'_>], width: usize) -> Vec<Vec<Span<'static>>> {
    let graphemes = cell_graphemes(cell);
    let Some(first) = graphemes.iter().position(|g| !is_space(g)) else {
        return vec![Vec::new()];
    };
    let last = graphemes.iter().rposition(|g| !is_space(g)).unwrap();
    let graphemes = &graphemes[first..=last];
    let mut lines: Vec<Vec<Grapheme>> = Vec::new();
    let mut current: Vec<Grapheme> = Vec::new();
    let mut current_width = 0;
    let mut index = 0;
    while index < graphemes.len() {
        while index < graphemes.len() && is_space(&graphemes[index]) {
            index += 1;
        }
        let start = index;
        while index < graphemes.len() && !is_space(&graphemes[index]) {
            index += 1;
        }
        if start == index {
            break;
        }
        let word = &graphemes[start..index];
        let word_width: usize = word.iter().map(|g| g.width).sum();
        if word_width > width {
            // The word cannot fit any column: break it by grapheme.
            if !current.is_empty() {
                lines.push(std::mem::take(&mut current));
            }
            let mut chunk_width = 0;
            for grapheme in word {
                let (symbol, glyph_width) = if grapheme.width > width {
                    ("\u{fffd}".to_owned(), 1)
                } else {
                    (grapheme.symbol.clone(), grapheme.width)
                };
                if chunk_width + glyph_width > width {
                    lines.push(std::mem::take(&mut current));
                    chunk_width = 0;
                }
                current.push(Grapheme {
                    symbol,
                    style: grapheme.style,
                    width: glyph_width,
                });
                chunk_width += glyph_width;
            }
            current_width = chunk_width;
        } else {
            if !current.is_empty() && current_width + 1 + word_width > width {
                lines.push(std::mem::take(&mut current));
                current_width = 0;
            }
            if !current.is_empty() {
                current.push(Grapheme {
                    symbol: " ".to_owned(),
                    style: word[0].style,
                    width: 1,
                });
                current_width += 1;
            }
            current.extend(word.iter().cloned());
            current_width += word_width;
        }
    }
    if !current.is_empty() || lines.is_empty() {
        lines.push(current);
    }
    lines.into_iter().map(to_spans).collect()
}

/// The widest unbreakable word in a cell, at least one column.
fn longest_word(cell: &[Span<'_>]) -> usize {
    let graphemes = cell_graphemes(cell);
    let mut longest = 0;
    let mut run = 0;
    for grapheme in &graphemes {
        if is_space(grapheme) {
            longest = longest.max(run);
            run = 0;
        } else {
            run += grapheme.width;
        }
    }
    longest.max(run).max(1)
}

fn cell_graphemes(cell: &[Span<'_>]) -> Vec<Grapheme> {
    cell.iter()
        .flat_map(|span| span.styled_graphemes(Style::default()))
        .map(|grapheme| Grapheme {
            symbol: grapheme.symbol.to_owned(),
            style: grapheme.style,
            width: Span::raw(grapheme.symbol).width(),
        })
        .collect()
}

fn is_space(grapheme: &Grapheme) -> bool {
    grapheme.symbol.chars().all(char::is_whitespace)
}

/// Merges consecutive graphemes that share a style into spans.
fn to_spans(graphemes: Vec<Grapheme>) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    for grapheme in graphemes {
        match spans.last_mut() {
            Some(last) if last.style == grapheme.style => {
                last.content.to_mut().push_str(&grapheme.symbol);
            }
            _ => spans.push(Span::styled(grapheme.symbol, grapheme.style)),
        }
    }
    spans
}

fn owned(line: &Line<'_>) -> Line<'static> {
    Line {
        spans: owned_spans(&line.spans),
        style: line.style,
        alignment: line.alignment,
    }
}

fn owned_spans(spans: &[Span<'_>]) -> Vec<Span<'static>> {
    spans
        .iter()
        .map(|span| Span {
            content: Cow::Owned(span.content.to_string()),
            style: span.style,
        })
        .collect()
}

fn span_width(spans: &[Span<'_>]) -> usize {
    spans.iter().map(Span::width).sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown::ThemeMarkdown;
    use ratatui::style::{Color, Modifier};

    fn styles() -> ThemeMarkdown {
        ThemeMarkdown {
            table_border: Style::default().fg(Color::Indexed(8)),
            table_header: Style::default().add_modifier(Modifier::BOLD),
            ..ThemeMarkdown::default()
        }
    }

    fn render(source: &str, width: u16) -> Vec<String> {
        let options = tui_markdown::Options::new(styles());
        let text = tui_markdown::from_str_with_options(source, &options);
        fit(text, width, &styles())
            .lines
            .iter()
            .map(|line| line.to_string())
            .collect()
    }

    #[test]
    fn wide_tables_shrink_columns_and_wrap_cells_inside_the_frame() {
        let source = "| Module | Role |\n|---|---|\n| Theme | The single source of truth |\n| Highlight | Adapter |";
        assert_eq!(
            render(source, 30),
            [
                "┌───────────┬────────────────┐",
                "│ Module    │ Role           │",
                "├───────────┼────────────────┤",
                "│ Theme     │ The single     │",
                "│           │ source of      │",
                "│           │ truth          │",
                "│ Highlight │ Adapter        │",
                "└───────────┴────────────────┘",
            ]
        );
    }

    #[test]
    fn tables_that_fit_are_untouched() {
        let source = "| A | B |\n|---|---|\n| 1 | 2 |";
        assert_eq!(
            render(source, 20),
            [
                "┌───┬───┐",
                "│ A │ B │",
                "├───┼───┤",
                "│ 1 │ 2 │",
                "└───┴───┘",
            ]
        );
    }

    #[test]
    fn alignment_is_preserved_when_columns_shrink() {
        let source = "| name | value |\n|:-----|------:|\n| a    | one two |";
        assert_eq!(
            render(source, 16),
            [
                "┌──────┬───────┐",
                "│ name │ value │",
                "├──────┼───────┤",
                "│ a    │   one │",
                "│      │   two │",
                "└──────┴───────┘",
            ]
        );
    }

    #[test]
    fn unbreakable_words_split_by_grapheme_when_the_budget_cannot_hold_them() {
        let source = "| Module | Role |\n|---|---|\n| Theme | Adapter |";
        assert_eq!(
            render(source, 14),
            [
                "┌─────┬──────┐",
                "│ Mod │ Role │",
                "│ ule │      │",
                "├─────┼──────┤",
                "│ The │ Adap │",
                "│ me  │ ter  │",
                "└─────┴──────┘",
            ]
        );
    }

    #[test]
    fn too_narrow_viewports_keep_the_original_table() {
        let source = "| aa | bb |\n|----|----|";
        assert_eq!(
            render(source, 6),
            ["┌────┬────┐", "│ aa │ bb │", "├────┼────┤", "└────┴────┘",]
        );
    }

    #[test]
    fn blockquote_prefixes_are_preserved_on_every_line() {
        let source = "> | aaa | bbb |\n> |-----|-----|\n> | 1 | 2 |";
        let lines = render(source, 12);
        assert!(lines.iter().all(|line| line.starts_with("> ")));
        assert!(lines.iter().all(|line| line.chars().count() <= 12));
        assert_eq!(lines[0], "> ┌───┬────┐");
        assert_eq!(lines[1], "> │ a │ bb │");
        assert_eq!(lines[4], "> ├───┼────┤");
        assert_eq!(lines[5], "> │ 1 │ 2  │");
    }

    #[test]
    fn prose_and_box_art_that_are_not_tables_are_untouched() {
        assert_eq!(
            render("plain text\n\n- item one", 20),
            ["plain text", "", "- item one"]
        );
        // Not a Markdown table, and the border glyphs do not carry the
        // theme's table border style, so the paragraph passes through.
        assert_eq!(
            render("┌───┬───┐\n│ x │ y │\n└───┴───┘", 10),
            ["┌───┬───┐ │ x │ y │ └───┴───┘"]
        );
    }

    #[test]
    fn inline_styles_survive_the_relayout() {
        let source = "| A | Longer column |\n|---|---|\n| **bold** | plain |";
        let options = tui_markdown::Options::new(styles());
        let text = tui_markdown::from_str_with_options(source, &options);
        let fitted = fit(text, 20, &styles());
        let row = &fitted.lines[4];
        assert_eq!(row.to_string(), "│ bold │ plain     │");
        assert!(
            row.spans
                .iter()
                .any(|span| span.content == "bold"
                    && span.style.add_modifier.contains(Modifier::BOLD))
        );
        assert!(row
            .spans
            .iter()
            .any(|span| span.content == "│" && span.style.fg == Some(Color::Indexed(8))));
    }
}
