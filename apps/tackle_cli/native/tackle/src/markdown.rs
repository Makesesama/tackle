//! Theme-driven Markdown styles for the native prose renderer.
//!
//! The Elixir theme owns every color: `Tackle.CLI.TUI.Theme.markdown_styles/0`
//! sends one wire style per Markdown element with each prose cell, and this
//! module adapts that map into a `tui_markdown::StyleSheet`. The crate's own
//! defaults (cyan heading bands, white-on-black code, green blockquotes)
//! would ignore the selected palette, so the shell never renders with them.
//!
//! Heading markers are hidden: a heading reads as bold accent text rather
//! than literal `#`s, which keeps assistant prose quiet. Everything else the
//! renderer needs — alert icons and labels, code fences — keeps the crate's
//! text defaults, because those carry no color.

use ratatui::style::Style;
use rustler::NifMap;
use tui_markdown::{AlertKind, StyleSheet};

use crate::conversation::{style as wire_style, WireStyle};

/// The Markdown element styles on the wire: one `{fg, bg, underline, bits}`
/// tuple per element, keyed by the atom `Tackle.CLI.TUI.Theme` documents.
#[derive(NifMap, Clone)]
pub(crate) struct MarkdownWire {
    pub(crate) heading: WireStyle,
    pub(crate) code: WireStyle,
    pub(crate) link: WireStyle,
    pub(crate) blockquote: WireStyle,
    pub(crate) meta: WireStyle,
    pub(crate) math: WireStyle,
    pub(crate) alert_note: WireStyle,
    pub(crate) alert_tip: WireStyle,
    pub(crate) alert_important: WireStyle,
    pub(crate) alert_warning: WireStyle,
    pub(crate) alert_caution: WireStyle,
    pub(crate) table_header: WireStyle,
    pub(crate) table_cell: WireStyle,
    pub(crate) table_border: WireStyle,
}

/// The decoded stylesheet the Markdown renderer consults.
#[derive(Clone, Default)]
pub(crate) struct ThemeMarkdown {
    pub(crate) heading: Style,
    pub(crate) code: Style,
    pub(crate) link: Style,
    pub(crate) blockquote: Style,
    pub(crate) meta: Style,
    pub(crate) math: Style,
    pub(crate) alert_note: Style,
    pub(crate) alert_tip: Style,
    pub(crate) alert_important: Style,
    pub(crate) alert_warning: Style,
    pub(crate) alert_caution: Style,
    pub(crate) table_header: Style,
    pub(crate) table_cell: Style,
    pub(crate) table_border: Style,
}

impl ThemeMarkdown {
    /// Decodes the wire styles, rejecting modifier bits the wire cannot carry.
    pub(crate) fn from_wire(
        MarkdownWire {
            heading,
            code,
            link,
            blockquote,
            meta,
            math,
            alert_note,
            alert_tip,
            alert_important,
            alert_warning,
            alert_caution,
            table_header,
            table_cell,
            table_border,
        }: MarkdownWire,
    ) -> rustler::NifResult<Self> {
        Ok(Self {
            heading: wire_style(heading)?,
            code: wire_style(code)?,
            link: wire_style(link)?,
            blockquote: wire_style(blockquote)?,
            meta: wire_style(meta)?,
            math: wire_style(math)?,
            alert_note: wire_style(alert_note)?,
            alert_tip: wire_style(alert_tip)?,
            alert_important: wire_style(alert_important)?,
            alert_warning: wire_style(alert_warning)?,
            alert_caution: wire_style(alert_caution)?,
            table_header: wire_style(table_header)?,
            table_cell: wire_style(table_cell)?,
            table_border: wire_style(table_border)?,
        })
    }
}

impl StyleSheet for ThemeMarkdown {
    fn heading(&self, _level: u8) -> Style {
        self.heading
    }

    fn code(&self) -> Style {
        self.code
    }

    fn link(&self) -> Style {
        self.link
    }

    fn blockquote(&self) -> Style {
        self.blockquote
    }

    fn heading_meta(&self) -> Style {
        self.meta
    }

    fn metadata_block(&self) -> Style {
        self.meta
    }

    fn html(&self) -> Style {
        self.meta
    }

    fn footnote_ref(&self) -> Style {
        self.meta
    }

    fn footnote_def(&self) -> Style {
        self.meta
    }

    fn image_alt(&self) -> Style {
        self.meta
    }

    fn math_inline(&self) -> Style {
        self.math
    }

    fn math_display(&self) -> Style {
        self.math
    }

    fn alert(&self, kind: AlertKind) -> Style {
        match kind {
            AlertKind::Note => self.alert_note,
            AlertKind::Tip => self.alert_tip,
            AlertKind::Important => self.alert_important,
            AlertKind::Warning => self.alert_warning,
            AlertKind::Caution => self.alert_caution,
        }
    }

    fn table_header(&self) -> Style {
        self.table_header
    }

    fn table_cell(&self) -> Style {
        self.table_cell
    }

    fn table_border(&self) -> Style {
        self.table_border
    }

    fn definition_term(&self) -> Style {
        // No color of its own: bold over the cell's base style.
        Style::new().bold()
    }

    fn heading_marker(&self, _level: u8) -> &str {
        ""
    }
}
