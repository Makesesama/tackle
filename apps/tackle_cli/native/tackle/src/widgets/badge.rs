//! Minimal custom Widget; future Ratatui addon adapters belong alongside this module.
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    widgets::{Paragraph, Widget},
};

pub struct Badge<'a> {
    pub label: &'a str,
}

impl Widget for Badge<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        let style = Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD);
        Paragraph::new(format!("[ {} ]", self.label))
            .style(style)
            .render(area, buffer);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clips_to_the_supplied_area() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 12, 3));
        Badge { label: "Native" }.render(Rect::new(2, 1, 4, 1), &mut buffer);
        assert_eq!(buffer[(2, 1)].symbol(), "[");
        assert_eq!(buffer[(5, 1)].symbol(), "a");
        assert_eq!(buffer[(6, 1)].symbol(), " ");
        assert_eq!(buffer[(2, 0)].symbol(), " ");
        assert_eq!(buffer[(2, 1)].fg, Color::Cyan);
    }
}
