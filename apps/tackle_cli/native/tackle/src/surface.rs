//! Owned, styled text runs only: never exchange pointers with ExRatatui's NIF.
use ratatui::{
    buffer::{Buffer, CellDiffOption, CellWidth},
    style::{Color, Modifier, Style},
};
use rustler::{Encoder, Env, Term};

pub type Line = Vec<Run>;

#[derive(Debug, PartialEq)]
pub struct Run {
    text: String,
    style: Style,
}

impl Encoder for Run {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        (
            &self.text,
            WireColor(self.style.fg.unwrap_or_default()),
            WireColor(self.style.bg.unwrap_or_default()),
            WireColor(self.style.underline_color.unwrap_or_default()),
            self.style.add_modifier.bits(),
        )
            .encode(env)
    }
}

struct WireColor(Color);

impl Encoder for WireColor {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // Named colors occupy the first 16 ANSI palette slots. No dynamic atoms.
        let index = match self.0 {
            Color::Reset => return rustler::types::atom::nil().encode(env),
            Color::Rgb(r, g, b) => return (r, g, b).encode(env),
            Color::Indexed(index) => index,
            Color::Black => 0,
            Color::Red => 1,
            Color::Green => 2,
            Color::Yellow => 3,
            Color::Blue => 4,
            Color::Magenta => 5,
            Color::Cyan => 6,
            Color::Gray => 7,
            Color::DarkGray => 8,
            Color::LightRed => 9,
            Color::LightGreen => 10,
            Color::LightYellow => 11,
            Color::LightBlue => 12,
            Color::LightMagenta => 13,
            Color::LightCyan => 14,
            Color::White => 15,
        };
        index.encode(env)
    }
}

pub fn lines(buffer: &Buffer) -> Result<Vec<Line>, &'static str> {
    let supported = Modifier::BOLD
        | Modifier::DIM
        | Modifier::ITALIC
        | Modifier::UNDERLINED
        | Modifier::REVERSED
        | Modifier::CROSSED_OUT;
    let mut lines = Vec::with_capacity(usize::from(buffer.area.height));
    for y in buffer.area.top()..buffer.area.bottom() {
        let mut line: Line = vec![];
        let mut x = buffer.area.left();
        while x < buffer.area.right() {
            let cell = &buffer[(x, y)];
            if cell.diff_option != CellDiffOption::None || !supported.contains(cell.modifier) {
                return Err("unsupported cell effects");
            }
            if cell.symbol().chars().any(char::is_control) {
                return Err("control character in rendered cell");
            }
            let style = cell.style();
            match line.last_mut() {
                Some(run) if run.style == style => run.text.push_str(cell.symbol()),
                _ => line.push(Run {
                    text: cell.symbol().to_owned(),
                    style,
                }),
            }
            // Wide glyphs own their continuation cells: do not emit extra spaces.
            x = x.saturating_add(cell.cell_width().max(1));
        }
        lines.push(line);
    }
    Ok(lines)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::layout::Rect;

    #[test]
    fn coalesces_styles_and_skips_wide_continuations() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 8, 1));
        buffer.set_string(0, 0, "界e\u{301}!", Style::new().fg(Color::Red));
        let rows = lines(&buffer).unwrap();
        assert_eq!(rows[0].len(), 2);
        assert_eq!(rows[0][0].text, "界e\u{301}!");
        assert_eq!(rows[0][1].text, "    ");
        assert_eq!(rows[0][0].style.fg, Some(Color::Red));
    }

    #[test]
    fn preserves_background_underline_and_modifiers() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 2, 1));
        let style = Style::new()
            .fg(Color::Rgb(1, 2, 3))
            .bg(Color::Indexed(42))
            .underline_color(Color::Blue)
            .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
        buffer.set_style(buffer.area, style);
        let rows = lines(&buffer).unwrap();
        assert_eq!(rows[0][0].text, "  ");
        assert_eq!(rows[0][0].style, buffer[(0, 0)].style());
    }

    #[test]
    fn refuses_terminal_effects_and_control_bytes() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 1, 1));
        buffer[(0, 0)].set_diff_option(CellDiffOption::Skip);
        assert!(lines(&buffer).is_err());
        buffer[(0, 0)].reset();
        buffer[(0, 0)].set_symbol("\x1b");
        assert!(lines(&buffer).is_err());
    }
}
