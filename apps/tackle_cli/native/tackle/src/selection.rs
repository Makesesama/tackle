//! Screen-cell selection uses the same painted buffer as the transcript, including
//! wide graphemes. Coordinates are document rows and terminal columns, half-open.
use crate::{conversation::ConversationResource, MAX_CELLS};
use ratatui::{
    buffer::{Buffer, CellWidth},
    layout::Rect,
    style::{Modifier, Style},
    widgets::Widget,
};
use rustler::{Error, NifResult, ResourceArc};

pub type Point = (usize, u16);
pub type Range = (Point, Point);

fn row(resource: &ConversationResource, y: usize) -> Buffer {
    let area = Rect::new(0, 0, resource.1, 1);
    let mut buffer = Buffer::empty(area);
    resource
        .0
        .widget(y, &[], Style::default())
        .render(area, &mut buffer);
    buffer
}

fn cells(buffer: &Buffer, y: u16) -> Vec<(u16, u16, String)> {
    let mut result = Vec::new();
    let mut x = 0;
    while x < buffer.area.width {
        let cell = &buffer[(x, y)];
        let width = cell.cell_width().max(1);
        result.push((x, width, cell.symbol().to_owned()));
        x = x.saturating_add(width);
    }
    result
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_row(
    resource: ResourceArc<ConversationResource>,
    y: usize,
) -> Vec<(u16, u16, String)> {
    if y >= resource.0.height {
        return vec![];
    }
    cells(&row(&resource, y), 0)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn conversation_selection_text(
    resource: ResourceArc<ConversationResource>,
    range: Range,
) -> NifResult<String> {
    let (start, end) = range;
    if start > end || end.0 >= resource.0.height || start.1 > resource.1 || end.1 > resource.1 {
        return Err(Error::BadArg);
    }
    // Bound work and clipboard payloads, rather than allocating an entire history buffer.
    if (end.0 - start.0 + 1).saturating_mul(usize::from(resource.1)) > MAX_CELLS * 16 {
        return Err(Error::Term(Box::new("selection too large")));
    }
    let mut rows = Vec::new();
    // Render bounded batches rather than rewrapping the entire logical line
    // for every row. At the selection limit there are at most 17 batches.
    let batch_size = (MAX_CELLS / usize::from(resource.1)).min(usize::from(u16::MAX));
    let mut offset = start.0;
    while offset <= end.0 {
        let height = batch_size.min(end.0 - offset + 1) as u16;
        let area = Rect::new(0, 0, resource.1, height);
        let mut buffer = Buffer::empty(area);
        resource
            .0
            .widget(offset, &[], Style::default())
            .render(area, &mut buffer);
        for local_y in 0..height {
            let y = offset + usize::from(local_y);
            let mut text = String::new();
            for (x, width, symbol) in cells(&buffer, local_y) {
                if (y, x.saturating_add(width)) > start && (y, x) < end {
                    text.push_str(&symbol);
                }
            }
            rows.push(text.trim_end_matches(' ').to_owned());
        }
        offset += usize::from(height);
    }
    Ok(rows.join("\n"))
}

pub fn highlight(buffer: &mut Buffer, body: Rect, offset: usize, range: Option<Range>) {
    let Some((start, end)) = range else {
        return;
    };
    for y in body.top()..body.bottom() {
        let row = offset.saturating_add(usize::from(y - body.y));
        let mut x = body.left();
        while x < body.right() {
            let width = buffer[(x, y)].cell_width().max(1);
            let col = x - body.x;
            if (row, col.saturating_add(width)) > start && (row, col) < end {
                // Reverse each glyph's own colours, preserving syntax styling.
                buffer[(x, y)].set_style(Style::default().add_modifier(Modifier::REVERSED));
            }
            x = x.saturating_add(width);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_and_extraction_share_wide_cell_boundaries() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 8, 1));
        buffer.set_string(0, 0, "界e\u{301}xyz", Style::default());
        assert_eq!(cells(&buffer, 0)[0], (0, 2, "界".into()));
        assert_eq!(cells(&buffer, 0)[1], (2, 1, "e\u{301}".into()));
        highlight(
            &mut buffer,
            Rect::new(0, 0, 8, 1),
            4,
            Some(((4, 1), (4, 3))),
        );
        assert!(buffer[(0, 0)].modifier.contains(Modifier::REVERSED));
        assert!(buffer[(2, 0)].modifier.contains(Modifier::REVERSED));
        assert!(!buffer[(3, 0)].modifier.contains(Modifier::REVERSED));
    }
}
