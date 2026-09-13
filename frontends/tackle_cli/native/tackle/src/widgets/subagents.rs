//! Minimal sidebar for currently running delegated tasks.
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget, Wrap},
};

#[derive(Clone, Debug)]
pub struct SubagentTask {
    pub profile: String,
    pub assignment: String,
    pub elapsed: Option<String>,
}

pub struct Subagents<'a> {
    pub tasks: &'a [SubagentTask],
    pub accent: Style,
    pub muted: Style,
    pub text: Style,
    pub selected: Option<usize>,
    pub spinner_frame: usize,
}

impl Widget for Subagents<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        if area.is_empty() || self.tasks.is_empty() {
            return;
        }

        let block = Block::new()
            .borders(Borders::LEFT)
            .border_style(self.muted)
            .title(Span::styled(" Tasks ", self.muted));
        let inner = block.inner(area);
        block.render(area, buffer);

        if inner.is_empty() {
            return;
        }

        let mut lines = Vec::new();
        for (index, task) in self.tasks.iter().enumerate() {
            let selected = self.selected == Some(index);
            let marker = if selected { "› " } else { "  " };
            let spinner =
                ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][self.spinner_frame % 10];
            let marker_style = if selected {
                self.accent.add_modifier(Modifier::BOLD)
            } else {
                self.accent
            };
            if index > 0 {
                lines.push(Line::default());
            }

            let mut heading = vec![
                Span::styled(marker, marker_style),
                Span::styled(format!("{spinner} "), self.accent),
                Span::styled(
                    task.profile.as_str(),
                    self.text.add_modifier(Modifier::BOLD),
                ),
            ];
            if let Some(elapsed) = &task.elapsed {
                heading.push(Span::styled(format!("  {elapsed}"), self.muted));
            }
            lines.push(Line::from(heading));
            lines.push(Line::from(Span::styled(
                task.assignment.as_str(),
                self.muted,
            )));
        }

        Paragraph::new(lines)
            .wrap(Wrap { trim: true })
            .render(inner, buffer);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Color;

    fn rendered(buffer: &Buffer, y: u16) -> String {
        (0..buffer.area.width)
            .map(|x| buffer[(x, y)].symbol())
            .collect()
    }

    #[test]
    fn paints_running_tasks_in_a_quiet_sidebar() {
        let tasks = vec![SubagentTask {
            profile: "scout".into(),
            assignment: "Inspect the layout".into(),
            elapsed: Some("12s".into()),
        }];
        let mut buffer = Buffer::empty(Rect::new(0, 0, 24, 4));
        Subagents {
            tasks: &tasks,
            accent: Style::new().fg(Color::Cyan),
            muted: Style::new().fg(Color::DarkGray),
            text: Style::new().fg(Color::White),
            selected: None,
            spinner_frame: 0,
        }
        .render(buffer.area, &mut buffer);

        assert!(rendered(&buffer, 0).contains("Tasks"));
        assert!(rendered(&buffer, 1).contains("⠋ scout  12s"));
        assert!(rendered(&buffer, 2).contains("Inspect the layout"));
    }
}
