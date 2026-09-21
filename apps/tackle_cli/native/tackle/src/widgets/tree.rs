//! Conversation-tree viewport inspired by pi's tree selector: branch structure,
//! active-path markers, a fixed cursor gutter, and horizontal panning that keeps
//! deeply nested selected content visible.
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Widget,
};

#[derive(Clone, Debug)]
pub struct TreeNode {
    pub text: String,
    pub secondary: Option<String>,
    pub depth: usize,
    pub show_connector: bool,
    pub is_last: bool,
    pub ancestor_continues: Vec<bool>,
    pub active: bool,
    pub unsafe_entry: bool,
}

pub struct Tree<'a> {
    pub nodes: &'a [TreeNode],
    pub selected: usize,
    pub scroll_padding: usize,
    pub accent: Style,
    pub muted: Style,
    pub selection: Style,
    pub text: Style,
}

impl Widget for Tree<'_> {
    fn render(self, area: Rect, buffer: &mut Buffer) {
        if area.is_empty() || self.nodes.is_empty() {
            return;
        }

        let selected = self.selected.min(self.nodes.len() - 1);
        let height = usize::from(area.height);
        let start = viewport_start(self.nodes.len(), selected, height, self.scroll_padding);
        let end = (start + height).min(self.nodes.len());
        let body_width = usize::from(area.width.saturating_sub(2));
        let anchors: Vec<_> = (start..end)
            .map(|index| anchor_column(&self.nodes[index], self.nodes.get(index + 1)))
            .collect();
        let max_width = (start..end)
            .map(|index| row_width(&self.nodes[index], self.nodes.get(index + 1)))
            .max()
            .unwrap_or(0);
        let horizontal_scroll = horizontal_scroll(anchors[selected - start], max_width, body_width);

        for (visible_index, node) in self.nodes[start..end].iter().enumerate() {
            let index = start + visible_index;
            let y = area.y + visible_index as u16;
            let selected_row = index == selected;
            let row_area = Rect::new(area.x, y, area.width, 1);
            if selected_row {
                buffer.set_style(row_area, self.selection);
            }

            let cursor = if selected_row { "› " } else { "  " };
            Line::from(Span::styled(cursor, self.accent))
                .render(Rect::new(area.x, y, area.width.min(2), 1), buffer);

            if body_width == 0 {
                continue;
            }
            let body = row(
                node,
                self.nodes.get(index + 1),
                self.text,
                self.accent,
                self.muted,
                selected_row,
            );
            let body_area = Rect::new(area.x.saturating_add(2), y, area.width.saturating_sub(2), 1);
            // Paragraph-style horizontal clipping is applied by drawing into a
            // virtual line and copying its visible cells. This keeps the cursor
            // gutter fixed, like pi's selector.
            let virtual_width = max_width.max(body_width).min(65_535) as u16;
            let mut virtual_buffer = Buffer::empty(Rect::new(0, 0, virtual_width, 1));
            body.render(Rect::new(0, 0, virtual_width, 1), &mut virtual_buffer);
            for x in 0..body_area.width {
                let source_x = horizontal_scroll.saturating_add(usize::from(x));
                if source_x >= usize::from(virtual_width) {
                    break;
                }
                buffer[(body_area.x + x, y)] = virtual_buffer[(source_x as u16, 0)].clone();
                if selected_row {
                    buffer[(body_area.x + x, y)].set_style(self.selection);
                }
            }
        }
    }
}

fn row<'a>(
    node: &'a TreeNode,
    next: Option<&TreeNode>,
    text_style: Style,
    accent: Style,
    muted: Style,
    selected: bool,
) -> Line<'a> {
    let mut spans = Vec::new();
    let junction = opens_branch(node, next);
    let ends_branch = next.is_none_or(|next| {
        next.depth < node.depth || (next.depth == node.depth && next.show_connector)
    });
    for level in 0..node.depth {
        let final_level = level + 1 == node.depth;
        let prefix = if final_level && node.show_connector {
            match (node.is_last, junction) {
                (true, true) => "└──",
                (false, true) => "├──",
                (true, false) => "└─ ",
                (false, false) => "├─ ",
            }
        } else if final_level && junction {
            "└──"
        } else if final_level && ends_branch {
            "└─ "
        } else if final_level || node.ancestor_continues.get(level).copied().unwrap_or(false) {
            "│  "
        } else {
            "   "
        };
        spans.push(Span::styled(prefix, muted));
    }
    if junction {
        spans.push(Span::styled("┬ ", muted));
    }
    if node.active {
        spans.push(Span::styled("• ", accent));
    }
    let content_style = if selected {
        text_style.add_modifier(Modifier::BOLD)
    } else {
        text_style
    };
    spans.push(Span::styled(node.text.as_str(), content_style));
    if let Some(secondary) = &node.secondary {
        let style = if node.unsafe_entry {
            Style::new().fg(Color::Yellow)
        } else {
            muted
        };
        spans.push(Span::styled("  ", style));
        spans.push(Span::styled(secondary.as_str(), style));
    }
    Line::from(spans)
}

fn viewport_start(count: usize, selected: usize, height: usize, padding: usize) -> usize {
    if height == 0 || count <= height {
        return 0;
    }
    let padding = padding.min(height.saturating_sub(1) / 2);
    selected.saturating_sub(padding).min(count - height)
}

fn opens_branch(node: &TreeNode, next: Option<&TreeNode>) -> bool {
    next.is_some_and(|next| next.depth > node.depth)
}

fn anchor_column(node: &TreeNode, next: Option<&TreeNode>) -> usize {
    node.depth * 3 + usize::from(node.active) * 2 + usize::from(opens_branch(node, next)) * 2
}

fn row_width(node: &TreeNode, next: Option<&TreeNode>) -> usize {
    anchor_column(node, next)
        + Line::from(node.text.as_str()).width()
        + node
            .secondary
            .as_ref()
            .map(|secondary| 2 + Line::from(secondary.as_str()).width())
            .unwrap_or(0)
}

fn horizontal_scroll(anchor: usize, max_width: usize, viewport_width: usize) -> usize {
    let max_scroll = max_width.saturating_sub(viewport_width);
    if viewport_width == 0 || max_scroll == 0 {
        return 0;
    }
    let minimum_visible = (viewport_width / 3).clamp(4, 20).min(viewport_width);
    if anchor <= viewport_width.saturating_sub(minimum_visible) {
        return 0;
    }
    let context = (viewport_width / 4).clamp(2, 12);
    anchor.saturating_sub(context).min(max_scroll)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(text: &str, depth: usize, is_last: bool, ancestors: &[bool]) -> TreeNode {
        TreeNode {
            text: text.into(),
            secondary: None,
            depth,
            show_connector: depth > 0,
            is_last,
            ancestor_continues: ancestors.into(),
            active: false,
            unsafe_entry: false,
        }
    }

    fn rendered(buffer: &Buffer, y: u16) -> String {
        (0..buffer.area.width)
            .map(|x| buffer[(x, y)].symbol())
            .collect()
    }

    #[test]
    fn paints_connectors_active_path_and_selection() {
        let mut first = node("user: branch A", 1, false, &[]);
        first.active = true;
        let second = node("assistant: result", 2, true, &[true]);
        let nodes = vec![first, second];
        let mut buffer = Buffer::empty(Rect::new(0, 0, 32, 2));
        Tree {
            nodes: &nodes,
            selected: 1,
            scroll_padding: 2,
            accent: Style::new().fg(Color::Cyan),
            muted: Style::new().fg(Color::DarkGray),
            selection: Style::new().bg(Color::Blue),
            text: Style::new().fg(Color::White),
        }
        .render(buffer.area, &mut buffer);

        assert!(rendered(&buffer, 0).contains("├──┬ • user: branch A"));
        assert!(rendered(&buffer, 1).contains("› │  └─ assistant"));
        assert_eq!(buffer[(0, 1)].bg, Color::Blue);
        assert_eq!(buffer[(10, 1)].bg, Color::Blue);
    }

    #[test]
    fn branch_rails_survive_single_child_chains_and_nested_forks() {
        let continuation = |text, depth, ancestors: &[bool]| {
            let mut entry = node(text, depth, true, ancestors);
            entry.show_connector = false;
            entry
        };
        let nodes = vec![
            node("shared history", 0, true, &[]),
            node("branch A", 1, false, &[]),
            continuation("answer A", 2, &[true]),
            continuation("follow-up A", 2, &[true]),
            node("nested A1", 3, false, &[true, false]),
            continuation("answer A1", 4, &[true, false, true]),
            node("nested A2", 3, true, &[true, false]),
            node("branch B", 1, true, &[]),
            continuation("answer B", 2, &[false]),
            continuation("follow-up B", 2, &[false]),
        ];
        let lines: Vec<_> = nodes
            .iter()
            .enumerate()
            .map(|(index, node)| {
                row(
                    node,
                    nodes.get(index + 1),
                    Style::default(),
                    Style::default(),
                    Style::default(),
                    false,
                )
                .to_string()
            })
            .collect();
        assert_eq!(
            lines,
            vec![
                "┬ shared history",
                "├──┬ branch A",
                "│  │  answer A",
                "│  └──┬ follow-up A",
                "│     ├──┬ nested A1",
                "│     │  └─ answer A1",
                "│     └─ nested A2",
                "└──┬ branch B",
                "   │  answer B",
                "   └─ follow-up B",
            ]
        );
    }

    #[test]
    fn keeps_cursor_visible_while_panning_deep_rows() {
        let nodes = vec![node("deep selected content", 8, true, &[false; 8])];
        let mut buffer = Buffer::empty(Rect::new(0, 0, 18, 1));
        Tree {
            nodes: &nodes,
            selected: 0,
            scroll_padding: 0,
            accent: Style::default(),
            muted: Style::default(),
            selection: Style::default(),
            text: Style::default(),
        }
        .render(buffer.area, &mut buffer);
        let line = rendered(&buffer, 0);
        assert!(line.starts_with("› "));
        assert!(line.contains("deep"));
    }

    #[test]
    fn centers_selection_and_respects_edges() {
        assert_eq!(viewport_start(20, 0, 5, 2), 0);
        assert_eq!(viewport_start(20, 10, 5, 2), 8);
        assert_eq!(viewport_start(20, 19, 5, 2), 15);
    }
}
