//! Browse chrome and viewport, sharing the transcript's immutable history cells.
use super::conversation::Conversation;
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::Style,
    text::{Line, Span},
    widgets::Widget,
};

pub const PAGES: [&str; 6] = [
    "Transcript",
    "Overview",
    "Prompt",
    "Context",
    "Tools",
    "Events",
];

/// Chrome yields to content in a one-row pane.
pub fn body_height(height: u16) -> u16 {
    if height > 1 {
        height - 1
    } else {
        height
    }
}

pub fn scroll(offset: usize, total: usize, height: u16, delta: i64) -> usize {
    let end = total.saturating_sub(usize::from(height));
    let offset = offset.min(end);
    if delta < 0 {
        offset.saturating_sub(delta.unsigned_abs().min(usize::MAX as u64) as usize)
    } else {
        offset
            .saturating_add((delta as u64).min(usize::MAX as u64) as usize)
            .min(end)
    }
}

pub struct Browse<'a> {
    pub conversation: &'a Conversation,
    pub page: usize,
    pub offset: usize,
    pub selected: &'a [usize],
    pub accent: Style,
    pub muted: Style,
    pub selection: Style,
}

impl Widget for Browse<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        if area.is_empty() {
            return;
        }
        let height = body_height(area.height);
        if height < area.height {
            let spans: Vec<_> = PAGES
                .iter()
                .enumerate()
                .flat_map(|(index, title)| {
                    vec![
                        Span::styled(
                            if index == self.page {
                                format!("[{title}]")
                            } else {
                                (*title).to_owned()
                            },
                            if index == self.page {
                                self.accent
                            } else {
                                self.muted
                            },
                        ),
                        Span::raw(" "),
                    ]
                })
                .collect();
            let tabs = Line::from(spans);
            // Keep the selected page and navigation discoverable when tabs cannot fit.
            let tabs = if tabs.width() > usize::from(area.width) {
                Line::styled(
                    format!("< {} > {}/{}", PAGES[self.page], self.page + 1, PAGES.len()),
                    self.accent,
                )
            } else {
                tabs
            };
            tabs.render(Rect::new(area.x, area.y, area.width, 1), buffer);
        }
        let body = Rect::new(area.x, area.y + area.height - height, area.width, height);
        let offset = scroll(self.offset, self.conversation.height, height, 0);
        self.conversation
            .widget(offset, self.selected, self.selection)
            .render(body, buffer);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::widgets::conversation::HistoryCell;
    use std::sync::Arc;

    #[test]
    fn scrolling_is_saturating_and_respects_the_viewport() {
        assert_eq!(scroll(0, 100, 10, -1), 0);
        assert_eq!(scroll(0, 100, 10, i64::MAX), 90);
        assert_eq!(scroll(90, 100, 20, 0), 80);
        assert_eq!(scroll(90, 100, 10, i64::MIN), 0);
        assert_eq!(scroll(2, 1, 10, 100), 0);
    }

    #[test]
    fn tabs_and_content_render_at_nonzero_origins_and_tiny_sizes() {
        for (width, height) in [(0, 0), (1, 1), (20, 5), (100, 5)] {
            let cell = HistoryCell::plain("first\nsecond\nthird", width, Style::default());
            let conversation = Conversation::new(vec![Arc::new(cell)]);
            let area = Rect::new(2, 3, width, height);
            let mut buffer = Buffer::empty(area);
            Browse {
                conversation: &conversation,
                page: 5,
                offset: 0,
                selected: &[],
                accent: Style::default(),
                muted: Style::default(),
                selection: Style::default(),
            }
            .render(area, &mut buffer);
            if width >= 20 {
                let text: String = buffer.content.iter().map(|cell| cell.symbol()).collect();
                assert!(text.contains("Events"));
                assert!(text.contains("first"));
            }
            assert_eq!(
                body_height(height),
                if height > 1 { height - 1 } else { height }
            );
        }
    }
}
