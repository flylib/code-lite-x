//! The Git history panel, laid out like the Flutter version's Git tool window:
//! header, a thin vertical toolbar, the branch tree, the filter bar over the commit list
//! (with the commit graph), and the details of the selected commit.
// CodeLiteX: not part of upstream Lapce.

use std::{ops::Range, rc::Rc, sync::Arc};

use floem::{
    IntoView, Renderer, View,
    action::show_context_menu,
    event::EventListener,
    menu::{Menu, MenuItem},
    peniko::{
        Color,
        kurbo::{Cap, Circle, Line, Point, Size, Stroke},
    },
    reactive::{ReadSignal, SignalGet, SignalUpdate, SignalWith, create_memo, create_rw_signal},
    style::CursorStyle,
    views::{
        Decorators, VirtualVector, canvas, container, dyn_container, dyn_stack, empty, label,
        scroll::scroll, stack, svg, virtual_stack,
    },
};

use super::{kind::PanelKind, position::PanelPosition};
use crate::{
    app::clickable_icon,
    codelitex::{
        commit_graph::{GraphRow, MAX_GRAPH_LANES, graph_color, graph_width, lane_x},
        git::{GitChangeKind, GitCommitDetails, GitCommitInfo, GitRef},
        git_log::{DateFilter, GitLogData, LogInput, change_letter, format_time, ref_label},
        git_log_tree::{BranchIcon, BranchRow, FileRow, branch_rows, file_rows},
    },
    config::{LapceConfig, color::LapceColor, icon::LapceIcons},
    editor::EditorData,
    text_input::TextInputBuilder,
    window_tab::{Focus, WindowTabData},
};

const ROW_HEIGHT: f64 = 24.0;
const SIDE_TOOLBAR_WIDTH: f64 = 30.0;
const BRANCHES_WIDTH: f64 = 230.0;
const DETAILS_WIDTH: f64 = 320.0;
const AUTHOR_WIDTH: f64 = 120.0;
const DATE_WIDTH: f64 = 128.0;
/// The commit list keeps at least this much room before a side pane is dropped.
const LOG_MIN_WIDTH: f64 = 460.0;

type Config = ReadSignal<Arc<LapceConfig>>;

// Colours of the Flutter version's Git window.
fn subtle_border() -> Color {
    Color::from_rgb8(0x2E, 0x30, 0x35)
}
fn accent() -> Color {
    Color::from_rgb8(0x35, 0x74, 0xF0)
}
fn yellow() -> Color {
    Color::from_rgb8(0xE5, 0xA8, 0x4B)
}
fn green() -> Color {
    Color::from_rgb8(0x59, 0xA8, 0x69)
}
fn modified_blue() -> Color {
    Color::from_rgb8(0x68, 0x97, 0xBB)
}
fn commit_selected() -> Color {
    Color::from_rgb8(0x2E, 0x43, 0x6E)
}
fn tree_selected() -> Color {
    Color::from_rgba8(0x35, 0x74, 0xF0, 0x33)
}

const TAG_SVG: &str = r#"<svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" fill="currentColor"><path d="M1.5 2.5v5.2c0 .27.1.52.29.71l6.8 6.8a1 1 0 0 0 1.42 0l4.9-4.9a1 1 0 0 0 0-1.42l-6.8-6.8A1 1 0 0 0 7.4 1.1H2.9a1.4 1.4 0 0 0-1.4 1.4zm3.2.3a1.2 1.2 0 1 1 0 2.4 1.2 1.2 0 0 1 0-2.4z"/></svg>"#;
const STAR_SVG: &str = r#"<svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" fill="currentColor"><path d="M8 1.2l2.05 4.45 4.85.55-3.6 3.3 1 4.8L8 11.8l-4.3 2.5 1-4.8-3.6-3.3 4.85-.55z"/></svg>"#;

pub fn git_log_panel(
    window_tab_data: Rc<WindowTabData>,
    _position: PanelPosition,
) -> impl View {
    let data = window_tab_data.git_log.clone();
    let config = data.common.config;
    let focus = data.common.focus;
    data.ensure_loaded();

    // A narrow window gives up the details first, then the branches; the log keeps its room.
    // This only affects the layout, not what the user switched on.
    let width = create_rw_signal(0.0);
    let layout = {
        let data = data.clone();
        create_memo(move |_| {
            let mut room = width.get() - SIDE_TOOLBAR_WIDTH - LOG_MIN_WIDTH;
            let details = data.show_details.get() && room >= DETAILS_WIDTH + 1.0;
            if details {
                room -= DETAILS_WIDTH + 1.0;
            }
            let branches = data.show_branches.get() && room >= BRANCHES_WIDTH + 1.0;
            (branches, details)
        })
    };

    stack((
        header(window_tab_data.clone(), data.clone()),
        stack((
            side_toolbar(data.clone()),
            branches_pane(data.clone()).style(move |s| s.apply_if(!layout.get().0, |s| s.hide())),
            log_pane(data.clone()),
            details_pane(data.clone()).style(move |s| s.apply_if(!layout.get().1, |s| s.hide())),
        ))
        .style(|s| s.flex_row().width_full().min_height(0.0).flex_grow(1.0).flex_basis(0.0)),
    ))
    .on_resize(move |rect| width.set(rect.width()))
    .on_event_cont(EventListener::PointerDown, move |_| {
        if focus.get_untracked() != Focus::Panel(PanelKind::GitLog) {
            focus.set(Focus::Panel(PanelKind::GitLog));
        }
    })
    .style(move |s| {
        let config = config.get();
        s.flex_col()
            .size_pct(100.0, 100.0)
            .font_size(12.0)
            .color(config.color(LapceColor::PANEL_FOREGROUND))
            .background(config.color(LapceColor::PANEL_BACKGROUND))
    })
    .debug_name("Git Log Panel")
}

// ----- small pieces -----------------------------------------------------------------------

fn dim(config: Config) -> Color {
    config.get().color(LapceColor::PANEL_FOREGROUND_DIM)
}

fn icon_button<S: std::fmt::Display + 'static>(
    config: Config,
    icon: &'static str,
    tooltip: S,
    on_click: impl Fn() + 'static,
    active: impl Fn() -> bool + 'static,
) -> impl View {
    icon_button_disabled(config, icon, tooltip, on_click, active, || false)
}

fn icon_button_disabled<S: std::fmt::Display + 'static>(
    config: Config,
    icon: &'static str,
    tooltip: S,
    on_click: impl Fn() + 'static,
    active: impl Fn() -> bool + 'static,
    disabled: impl Fn() -> bool + Copy + 'static,
) -> impl View {
    let tip = tooltip.to_string();
    clickable_icon(move || icon, on_click, active, disabled, move || tip.clone(), config)
        .style(|s| s.margin_horiz(1.0))
}

fn divider_h() -> impl View {
    empty().style(|s| s.width_full().height(1.0).flex_shrink(0.0).background(subtle_border()))
}

/// A one-line text box bound to one of the panel's editors.
fn text_box(data: GitLogData, editor: EditorData, input: LogInput, placeholder: &'static str) -> impl View {
    let focus = data.common.focus;
    let active = data.active_input;
    let cursor_x = create_rw_signal(0.0);
    let is_focused = move || focus.get() == Focus::Panel(PanelKind::GitLog) && active.get() == input;
    scroll(
        TextInputBuilder::new()
            .is_focused(is_focused)
            .build_editor(editor)
            .placeholder(move || placeholder.to_string())
            .on_cursor_pos(move |point| cursor_x.set(point.x))
            .style(|s| s.padding_vert(3.0).min_width_pct(100.0)),
    )
    .ensure_visible(move || Size::new(20.0, 0.0).to_rect().with_origin(Point::new(cursor_x.get(), 0.0)))
    .scroll_style(|s| s.hide_bars(true))
    .on_event_cont(EventListener::PointerDown, move |_| {
        focus.set(Focus::Panel(PanelKind::GitLog));
        data.focus_input(input);
    })
    .style(|s| s.flex_grow(1.0).min_width(0.0).cursor(CursorStyle::Text).items_center())
}

fn scroll_fill(child: impl View + 'static) -> impl View {
    scroll_fill_with(child, |_| {})
}

/// A scroll area that fills its parent; `on_scroll` gets the visible rectangle.
fn scroll_fill_with(
    child: impl View + 'static,
    on_scroll: impl Fn(floem::peniko::kurbo::Rect) + 'static,
) -> impl View {
    container(scroll(child).on_scroll(on_scroll).style(|s| s.absolute().size_pct(100.0, 100.0)))
        .style(|s| s.size_full())
}

// ----- header and side toolbar ------------------------------------------------------------

fn header(window_tab_data: Rc<WindowTabData>, data: GitLogData) -> impl View {
    let config = data.common.config;
    let refresh = data.clone();
    let panel = window_tab_data.panel.clone();
    let focus = data.common.focus;
    stack((
        label(|| "Git".to_string()).style(|s| s.font_bold()),
        // Log is the only tab; the underline marks it as selected
        label(|| "Log".to_string()).style(move |s| {
            s.margin_left(18.0)
                .padding_horiz(6.0)
                .height(32.0)
                .items_center()
                .border_bottom(2.0)
                .border_color(accent())
                .color(config.get().color(LapceColor::EDITOR_FOREGROUND))
        }),
        empty().style(|s| s.flex_grow(1.0)),
        icon_button(config, LapceIcons::GIT_REFRESH, "Refresh", move || refresh.refresh(), || false),
        icon_button(
            config,
            LapceIcons::GIT_HIDE,
            "Hide",
            move || {
                panel.hide_panel(&PanelKind::GitLog);
                focus.set(Focus::Workbench);
            },
            || false,
        ),
    ))
    .style(|s| {
        s.width_full()
            .height(32.0)
            .flex_shrink(0.0)
            .items_center()
            .padding_left(12.0)
            .padding_right(4.0)
            .border_bottom(1.0)
            .border_color(subtle_border())
    })
}

fn side_toolbar(data: GitLogData) -> impl View {
    let config = data.common.config;
    let show_branches = data.show_branches;
    let focus = data.common.focus;
    let toggle = data.clone();
    let search = data.clone();
    let refresh = data.clone();
    stack((
        icon_button(
            config,
            LapceIcons::GIT_CHEVRON_LEFT,
            "Hide / show branches",
            move || toggle.toggle_branches(),
            || false,
        )
        .style(move |s| s.apply_if(!show_branches.get(), |s| s.hide())),
        icon_button(
            config,
            LapceIcons::GIT_CHEVRON_RIGHT,
            "Hide / show branches",
            {
                let data = data.clone();
                move || data.toggle_branches()
            },
            || false,
        )
        .style(move |s| s.apply_if(show_branches.get(), |s| s.hide())),
        icon_button(
            config,
            LapceIcons::SEARCH,
            "Search commits (text or hash)",
            move || {
                focus.set(Focus::Panel(PanelKind::GitLog));
                search.focus_input(LogInput::Search);
            },
            || false,
        )
        .style(|s| s.margin_top(6.0)),
        icon_button(config, LapceIcons::GIT_REFRESH, "Refresh", move || refresh.refresh(), || false)
            .style(|s| s.margin_top(6.0)),
    ))
    .style(|s| {
        s.flex_col()
            .items_center()
            .width(SIDE_TOOLBAR_WIDTH)
            .flex_shrink(0.0)
            .padding_vert(6.0)
            .border_right(1.0)
            .border_color(subtle_border())
    })
}

// ----- branch tree ------------------------------------------------------------------------

fn branches_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    let refs = data.refs;
    let collapsed = data.branches_collapsed;
    let list = data.clone();

    stack((
        stack((
            svg(move || config.get().ui_svg(LapceIcons::SEARCH)).style(move |s| {
                s.size(14.0, 14.0).margin_right(6.0).color(dim(config))
            }),
            text_box(data.clone(), data.branch_search.clone(), LogInput::Branches, ""),
        ))
        .style(|s| {
            s.width_full()
                .height(32.0)
                .flex_shrink(0.0)
                .items_center()
                .padding_horiz(8.0)
                .border_bottom(1.0)
                .border_color(subtle_border())
        }),
        scroll_fill(
            dyn_stack(
                move || {
                    refs.with(|r| {
                        branch_rows(&r.local, &r.remote, &list.branch_query(), &collapsed.get())
                    })
                },
                |row| format!("{}:{}:{}:{:?}", row.key, row.expanded, row.is_current, row.icon),
                {
                    let data = data.clone();
                    move |row| branch_row(data.clone(), row)
                },
            )
            .style(|s| s.flex_col().width_full().padding_vert(4.0)),
        )
        .style(|s| s.flex_grow(1.0).flex_basis(0.0).min_height(0.0)),
    ))
    .style(|s| {
        s.flex_col()
            .width(BRANCHES_WIDTH)
            .flex_shrink(0.0)
            .height_full()
            .border_right(1.0)
            .border_color(subtle_border())
    })
}

fn chevron(config: Config, expandable: bool, expanded: bool) -> impl View {
    svg(move || {
        config.get().ui_svg(if expanded { LapceIcons::ITEM_OPENED } else { LapceIcons::ITEM_CLOSED })
    })
    .style(move |s| {
        let s = s.size(14.0, 14.0).margin_right(2.0).color(dim(config));
        if expandable { s } else { s.color(Color::TRANSPARENT) }
    })
}

fn branch_row(data: GitLogData, row: BranchRow) -> impl View {
    let config = data.common.config;
    let selected = data.branch;
    let revision = row.revision.clone();
    let for_style = row.revision.clone();
    let key = row.key.clone();
    let icon = row.icon;
    let bold = row.is_current;
    let click = data.clone();

    let icon_view = match icon {
        BranchIcon::None => empty().into_any(),
        BranchIcon::Folder => svg(move || config.get().ui_svg(LapceIcons::DIRECTORY_CLOSED))
            .style(move |s| s.size(14.0, 14.0).margin_right(6.0).color(dim(config)))
            .into_any(),
        BranchIcon::Current => svg(|| TAG_SVG.to_string())
            .style(|s| s.size(14.0, 14.0).margin_right(6.0).color(yellow()))
            .into_any(),
        BranchIcon::Star => svg(|| STAR_SVG.to_string())
            .style(|s| s.size(14.0, 14.0).margin_right(6.0).color(yellow()))
            .into_any(),
        BranchIcon::Branch => svg(move || config.get().ui_svg(LapceIcons::GIT_BRANCH))
            .style(move |s| s.size(14.0, 14.0).margin_right(6.0).color(dim(config)))
            .into_any(),
    };
    let depth = row.depth as f32;
    let (expandable, expanded) = (row.expandable, row.expanded);
    let name = row.label.clone();

    stack((
        chevron(config, expandable, expanded),
        icon_view,
        label(move || name.clone()).style(move |s| {
            let s = s.min_width(0.0).text_ellipsis();
            if bold { s.font_bold() } else { s }
        }),
    ))
    .on_click_stop(move |_| match &revision {
        Some(rev) => click.toggle_branch(rev),
        None => click.toggle_branch_group(&key),
    })
    .style(move |s| {
        let config = config.get();
        let is_selected = for_style.is_some() && selected.get() == for_style;
        s.width_full()
            .height(ROW_HEIGHT)
            .flex_shrink(0.0)
            .items_center()
            .padding_left(8.0 + depth * 16.0)
            .padding_right(8.0)
            .cursor(CursorStyle::Pointer)
            .hover(|s| s.background(config.color(LapceColor::PANEL_HOVERED_BACKGROUND)))
            .apply_if(is_selected, |s| s.background(tree_selected()))
    })
}

// ----- log: filter bar and commit list ----------------------------------------------------

fn log_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    stack((filter_bar(data.clone()), commit_list(data)))
        .style(move |s| {
            s.flex_col()
                .flex_grow(1.0)
                .flex_basis(0.0)
                .min_width(0.0)
                .height_full()
                .background(config.get().color(LapceColor::EDITOR_BACKGROUND))
        })
}

fn toggle_chip(config: Config, text: &'static str, tooltip: &'static str, on: ReadSignal<bool>, click: impl Fn() + 'static) -> impl View {
    let tip = tooltip.to_string();
    crate::app::tooltip_label(
        config,
        label(move || text.to_string())
            .on_click_stop(move |_| click())
            .style(move |s| {
                s.padding_horiz(4.0)
                    .padding_vert(2.0)
                    .margin_left(2.0)
                    .border_radius(4.0)
                    .font_bold()
                    .cursor(CursorStyle::Pointer)
                    .color(if on.get() { accent() } else { dim(config) })
                    .apply_if(on.get(), |s| s.background(accent().multiply_alpha(0.15)))
            }),
        move || tip.clone(),
    )
}

fn filter_bar(data: GitLogData) -> impl View {
    let config = data.common.config;
    let focus = data.common.focus;
    let active = data.active_input;
    let regex = data.regex;
    let match_case = data.match_case;
    let show_details = data.show_details;
    let (tr, tc, td, tf) = (data.clone(), data.clone(), data.clone(), data.clone());

    let search_box = stack((
        svg(move || config.get().ui_svg(LapceIcons::SEARCH))
            .style(move |s| s.size(14.0, 14.0).margin_right(4.0).color(dim(config))),
        text_box(data.clone(), data.search.clone(), LogInput::Search, "Text or hash"),
        toggle_chip(config, ".*", "Regular expression", regex.read_only(), move || tr.toggle_regex()),
        toggle_chip(config, "Cc", "Match case", match_case.read_only(), move || tc.toggle_match_case()),
    ))
    .style(move |s| {
        let focused = focus.get() == Focus::Panel(PanelKind::GitLog) && active.get() == LogInput::Search;
        s.flex_grow(3.0)
            .flex_basis(0.0)
            .min_width(0.0)
            .max_width(280.0)
            .height(26.0)
            .items_center()
            .padding_left(6.0)
            .padding_right(2.0)
            .border(1.0)
            .border_radius(4.0)
            .border_color(if focused { accent() } else { config.get().color(LapceColor::LAPCE_BORDER) })
            .background(config.get().color(LapceColor::EDITOR_BACKGROUND))
    });

    stack((
        search_box,
        stack((
            branch_dropdown(data.clone()),
            user_dropdown(data.clone()),
            date_dropdown(data.clone()),
            paths_filter(data.clone()),
        ))
        .style(|s| s.margin_left(6.0).items_center().flex_shrink(0.0)),
        empty().style(|s| s.flex_grow(1.0)),
        icon_button(config, LapceIcons::GIT_REFRESH, "Refresh", move || td.refresh(), || false),
        icon_button(
            config,
            LapceIcons::GIT_DETAILS,
            "Show details",
            move || tf.toggle_details(),
            move || show_details.get(),
        ),
    ))
    .style(|s| {
        s.width_full()
            .height(36.0)
            .flex_shrink(0.0)
            .items_center()
            .padding_horiz(6.0)
            .border_bottom(1.0)
            .border_color(subtle_border())
    })
}

/// A filter of the bar: grey label while unset; the value and a × once set. A click opens `menu`.
fn dropdown(
    config: Config,
    name: &'static str,
    value: impl Fn() -> Option<String> + Copy + 'static,
    open: impl Fn() + 'static,
    clear: impl Fn() + 'static,
) -> impl View {
    stack((
        label(move || match value() {
            Some(v) => format!("{name}: {v}"),
            None => name.to_string(),
        })
        .style(move |s| {
            s.color(if value().is_some() { config.get().color(LapceColor::EDITOR_FOREGROUND) } else { dim(config) })
                .max_width(220.0)
                .text_ellipsis()
        }),
        stack((
            svg(move || config.get().ui_svg(LapceIcons::CLOSE))
                .style(move |s| s.size(12.0, 12.0).color(dim(config)))
                .on_click_stop(move |_| clear())
                .style(move |s| s.apply_if(value().is_none(), |s| s.hide())),
            svg(move || config.get().ui_svg(LapceIcons::ITEM_OPENED))
                .style(move |s| s.size(14.0, 14.0).color(dim(config)).apply_if(value().is_some(), |s| s.hide())),
        ))
        .style(|s| s.margin_left(2.0)),
    ))
    .on_click_stop(move |_| open())
    .style(move |s| {
        s.height(26.0)
            .items_center()
            .padding_horiz(6.0)
            .margin_right(2.0)
            .border_radius(4.0)
            .cursor(CursorStyle::Pointer)
            .apply_if(value().is_some(), |s| s.background(accent().multiply_alpha(0.15)))
            .hover(|s| s.background(config.get().color(LapceColor::PANEL_HOVERED_BACKGROUND)))
    })
}

fn menu_item(text: String, checked: bool, action: impl Fn() + 'static) -> MenuItem {
    MenuItem::new(if checked { format!("✓ {text}") } else { text }).action(action)
}

fn branch_dropdown(data: GitLogData) -> impl View {
    let config = data.common.config;
    let branch = data.branch;
    let (open, clear) = (data.clone(), data.clone());
    dropdown(
        config,
        "Branch",
        move || branch.get(),
        move || {
            let current = open.branch.get_untracked();
            let mut menu = Menu::new("");
            if current.is_some() {
                let d = open.clone();
                menu = menu.entry(menu_item("All".into(), false, move || d.set_branch(None))).separator();
            }
            let (locals, remotes) = open.refs.with_untracked(|r| (r.local.clone(), r.remote.clone()));
            let names = std::iter::once("HEAD".to_string())
                .chain(locals.into_iter().map(|b| b.name))
                .chain(remotes.into_iter().map(|b| b.name));
            for name in names {
                let d = open.clone();
                let target = name.clone();
                menu = menu.entry(menu_item(name.clone(), current.as_deref() == Some(name.as_str()), move || {
                    d.set_branch(Some(target.clone()))
                }));
            }
            show_context_menu(menu, None);
        },
        move || clear.set_branch(None),
    )
}

fn user_dropdown(data: GitLogData) -> impl View {
    let config = data.common.config;
    let author = data.author;
    let (open, clear) = (data.clone(), data.clone());
    dropdown(
        config,
        "User",
        move || author.get(),
        move || {
            open.load_authors();
            let current = open.author.get_untracked();
            let mut menu = Menu::new("");
            if current.is_some() {
                let d = open.clone();
                menu = menu.entry(menu_item("All".into(), false, move || d.set_author(None))).separator();
            }
            let names = open.authors.get_untracked();
            if names.is_empty() {
                menu = menu.entry(MenuItem::new("Loading…").enabled(false));
            }
            for name in names {
                let d = open.clone();
                let target = name.clone();
                menu = menu.entry(menu_item(name.clone(), current.as_deref() == Some(name.as_str()), move || {
                    d.set_author(Some(target.clone()))
                }));
            }
            show_context_menu(menu, None);
        },
        move || clear.set_author(None),
    )
}

fn date_dropdown(data: GitLogData) -> impl View {
    let config = data.common.config;
    let date = data.date;
    let (open, clear) = (data.clone(), data.clone());
    dropdown(
        config,
        "Date",
        move || (date.get() != DateFilter::All).then(|| date.get().label().to_string()),
        move || {
            let current = open.date.get_untracked();
            let mut menu = Menu::new("");
            if current != DateFilter::All {
                let d = open.clone();
                menu = menu.entry(menu_item("All".into(), false, move || d.set_date(DateFilter::All))).separator();
            }
            for choice in DateFilter::CHOICES {
                let d = open.clone();
                menu = menu.entry(menu_item(choice.label().into(), current == choice, move || d.set_date(choice)));
            }
            show_context_menu(menu, None);
        },
        move || clear.set_date(DateFilter::All),
    )
}

/// The Paths filter turns into a text box while it is edited (Enter applies it).
fn paths_filter(data: GitLogData) -> impl View {
    let config = data.common.config;
    let paths = data.paths;
    let editing = data.paths_editing;
    let (open, clear) = (data.clone(), data.clone());
    stack((
        dropdown(
            config,
            "Paths",
            move || {
                let p = paths.get();
                (!p.is_empty()).then(|| p.join(", "))
            },
            move || open.edit_paths(),
            move || clear.set_paths(Vec::new()),
        )
        .style(move |s| s.apply_if(editing.get(), |s| s.hide())),
        stack((text_box(data.clone(), data.paths_input.clone(), LogInput::Paths, "src/, docs/readme.md"),))
            .style(move |s| {
                s.width(200.0)
                    .height(26.0)
                    .items_center()
                    .padding_horiz(6.0)
                    .border(1.0)
                    .border_radius(4.0)
                    .border_color(accent())
                    .apply_if(!editing.get(), |s| s.hide())
            }),
    ))
}

struct CommitItems {
    commits: im::Vector<GitCommitInfo>,
    graph: Arc<Vec<GraphRow>>,
    epoch: usize,
}

impl VirtualVector<(GitCommitInfo, GraphRow, usize)> for CommitItems {
    fn total_len(&self) -> usize {
        self.commits.len()
    }

    fn slice(&mut self, range: Range<usize>) -> impl Iterator<Item = (GitCommitInfo, GraphRow, usize)> {
        let epoch = self.epoch;
        let (commits, graph) = (&self.commits, &self.graph);
        range
            .filter_map(move |i| Some((commits.get(i)?.clone(), graph.get(i)?.clone(), epoch)))
            .collect::<Vec<_>>()
            .into_iter()
    }
}

fn commit_list(data: GitLogData) -> impl View {
    let config = data.common.config;
    let commits = data.commits;
    let error = data.error;
    let loading = data.loading;
    let loader = data.clone();
    let list_data = data.clone();

    let message = move || {
        if let Some(e) = error.get() {
            e
        } else if loading.get() {
            "Loading…".to_string()
        } else {
            "No matching commits".to_string()
        }
    };

    stack((
        label(message).style(move |s| {
            s.padding(12.0)
                .width_full()
                .justify_center()
                .color(dim(config))
                .apply_if(error.get().is_none() && !commits.with(|c| c.is_empty()), |s| s.hide())
        }),
        scroll_fill_with(
            virtual_stack(
                move || CommitItems { commits: commits.get(), graph: list_data.graph.get(), epoch: list_data.epoch.get() },
                |(c, _, epoch)| (c.oid.clone(), *epoch),
                {
                    let data = data.clone();
                    move |(commit, graph, _)| commit_row(data.clone(), commit, graph)
                },
            )
            .item_size_fixed(|| ROW_HEIGHT)
            .style(|s| s.flex_col().width_full()),
            move |viewport| {
                // near the end of what is loaded: fetch the next page
                let total = commits.with_untracked(|c| c.len()) as f64 * ROW_HEIGHT;
                if viewport.y1 + 10.0 * ROW_HEIGHT >= total {
                    loader.load_more();
                }
            },
        )
        .style(move |s| s.apply_if(error.get().is_some() || commits.with(|c| c.is_empty()), |s| s.hide())),
    ))
    .style(|s| s.flex_col().flex_grow(1.0).flex_basis(0.0).min_height(0.0))
}

fn commit_row(data: GitLogData, commit: GitCommitInfo, graph: GraphRow) -> impl View {
    let config = data.common.config;
    let selected = data.selected;
    let is_head = data.head.get_untracked().as_deref() == Some(commit.oid.as_str());
    let oid = commit.oid.clone();
    let for_style = commit.oid.clone();
    let click = data.clone();
    let author = commit.author_name.clone();
    let when = format_time(commit.timestamp);
    let subject = commit.summary.clone();
    let refs = commit.refs.clone();

    stack((
        graph_cell(config, graph, is_head),
        stack((
            label(move || subject.clone()).style(move |s| {
                let s = s.min_width(0.0).flex_shrink(1.0).text_ellipsis();
                if selected.get().as_deref() == Some(for_style.as_str()) {
                    s.color(config.get().color(LapceColor::EDITOR_FOREGROUND))
                } else {
                    s
                }
            }),
            ref_labels(config, refs),
        ))
        .style(|s| s.flex_grow(1.0).min_width(0.0).items_center()),
        label(move || author.clone()).style(move |s| {
            let s = s.width(AUTHOR_WIDTH).flex_shrink(0.0).margin_left(12.0).text_ellipsis();
            if is_head { s.font_bold() } else { s }
        }),
        label(move || when.clone()).style(|s| s.width(DATE_WIDTH).flex_shrink(0.0).text_ellipsis()),
    ))
    .on_click_stop(move |_| click.select(&oid))
    .style(move |s| {
        let hovered = config.get().color(LapceColor::PANEL_HOVERED_BACKGROUND);
        s.width_full()
            .height(ROW_HEIGHT)
            .items_center()
            .cursor(CursorStyle::Pointer)
            .hover(|s| s.background(hovered))
            .apply_if(selected.get().as_deref() == Some(commit.oid.as_str()), |s| s.background(commit_selected()))
    })
}

/// The lanes of one row: lines, then the dot (hollow for HEAD).
fn graph_cell(config: Config, row: GraphRow, is_head: bool) -> impl View {
    let width = graph_width(&row);
    let background = config.get_untracked().color(LapceColor::EDITOR_BACKGROUND);
    canvas(move |cx, size| {
        let h = size.height;
        let color = |i: usize| {
            let (r, g, b) = graph_color(i);
            Color::from_rgb8(r, g, b)
        };
        let stroke = Stroke::new(1.6).with_caps(Cap::Round);
        // lanes beyond the cell are drawn on its last lane instead of outside of it
        let x = |lane: usize| lane_x(lane.min(MAX_GRAPH_LANES - 1));
        for l in &row.lines {
            let line = Line::new((x(l.from_lane), l.from_y * h), (x(l.to_lane), l.to_y * h));
            cx.stroke(&line, color(l.color), &stroke);
        }
        let center = (x(row.lane), h / 2.0);
        cx.fill(&Circle::new(center, 4.0), color(row.color), 0.0);
        if is_head {
            cx.fill(&Circle::new(center, 2.0), background, 0.0);
        }
    })
    .style(move |s| s.width(width).height(ROW_HEIGHT).flex_shrink(0.0))
}

/// `origin & dev` with a tag icon: green, yellow when HEAD is among them.
fn ref_labels(config: Config, refs: Vec<GitRef>) -> impl View {
    let Some(text) = ref_label(&refs) else {
        return empty().into_any();
    };
    let color = if refs.iter().any(|r| r.is_head) { yellow() } else { green() };
    stack((
        svg(|| TAG_SVG.to_string()).style(move |s| s.size(13.0, 13.0).margin_right(3.0).flex_shrink(0.0).color(color)),
        label(move || text.clone()).style(move |s| s.max_width(220.0).text_ellipsis().color(dim(config))),
    ))
    .style(|s| s.margin_left(8.0).items_center().flex_shrink(0.0))
    .into_any()
}

// ----- details ----------------------------------------------------------------------------

fn details_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    let details = data.details;
    let selected = data.selected;
    let inner = data.clone();

    dyn_container(
        move || (details.get(), selected.get().is_some()),
        move |(details, has_selection)| match details {
            Some(Ok(d)) => commit_details(inner.clone(), d).into_any(),
            Some(Err(e)) => label(move || e.clone()).style(|s| s.padding(12.0)).into_any(),
            None => label(move || {
                if has_selection { "Loading…" } else { "Select a commit to view details" }.to_string()
            })
            .style(move |s| s.padding(12.0).width_full().justify_center().color(dim(config)))
            .into_any(),
        },
    )
    .style(move |s| {
        s.flex_col()
            .width(DETAILS_WIDTH)
            .flex_shrink(0.0)
            .height_full()
            .border_left(1.0)
            .border_color(subtle_border())
    })
}

fn commit_details(data: GitLogData, d: GitCommitDetails) -> impl View {
    let config = data.common.config;
    let files = d.files.clone();
    let repo = data.repo_name();
    let collapsed = data.files_collapsed;
    let (expand, collapse, open_diff) = (data.clone(), data.clone(), data.clone());
    let selected_file = data.selected_file;
    let no_files = files.is_empty();
    let rows_files = files.clone();
    let rows_data = data.clone();

    stack((
        stack((
            icon_button_disabled(
                config,
                LapceIcons::GIT_DIFF,
                "Show diff (or double-click a file)",
                move || open_diff.open_selected_file_diff(),
                || false,
                move || selected_file.get().is_none(),
            ),
            empty().style(|s| s.flex_grow(1.0)),
            icon_button(config, LapceIcons::FOLD_DOWN, "Expand all", move || expand.expand_all_files(), || false),
            icon_button(config, LapceIcons::FOLD_UP, "Collapse all", move || collapse.collapse_all_files(), || false),
        ))
        .style(|s| {
            s.width_full()
                .height(36.0)
                .flex_shrink(0.0)
                .items_center()
                .padding_horiz(6.0)
                .border_bottom(1.0)
                .border_color(subtle_border())
        }),
        stack((
            label(|| "No file changes".to_string()).style(move |s| {
                s.padding(12.0).width_full().justify_center().color(dim(config)).apply_if(!no_files, |s| s.hide())
            }),
            scroll_fill(
                dyn_stack(
                    move || file_rows(&repo, &rows_files, &collapsed.get()),
                    |row| format!("{}:{}", row.key, row.expanded),
                    move |row| file_row(rows_data.clone(), row),
                )
                .style(|s| s.flex_col().width_full().padding_vert(4.0)),
            )
            .style(move |s| s.apply_if(no_files, |s| s.hide())),
        ))
        .style(|s| {
            s.flex_col()
                .flex_grow(3.0)
                .flex_basis(0.0)
                .min_height(0.0)
                .background(yellow().multiply_alpha(0.06))
        }),
        divider_h(),
        scroll_fill(message_block(config, d)).style(|s| s.flex_grow(2.0).flex_basis(0.0).min_height(0.0)),
    ))
    .style(|s| s.flex_col().size_full())
}

fn status_color(config: Config, kind: GitChangeKind) -> Color {
    match kind {
        GitChangeKind::Added => green(),
        GitChangeKind::Deleted => dim(config),
        _ => modified_blue(),
    }
}

fn file_row(data: GitLogData, row: FileRow) -> impl View {
    let config = data.common.config;
    let selected = data.selected_file;
    let for_style = row.path.clone();
    let is_dir = row.dir_count.is_some();
    let color = row.kind.map(|k| status_color(config, k));
    let key = row.key.clone();
    let path = row.path.clone();
    let click = data.clone();
    let double_click = data.clone();
    let double_click_path = row.path.clone();
    let name = row.label.clone();
    let trailing = match (row.dir_count, &row.renamed_from) {
        (Some(n), _) => Some(format!("{n} {}", if n == 1 { "file" } else { "files" })),
        (None, Some(old)) => Some(format!("← {old}")),
        _ => None,
    };
    let depth = row.depth as f32;
    let (expanded, letter) = (row.expanded, row.kind.map(change_letter));
    let icon_path = std::path::PathBuf::from(&row.label);

    stack((
        chevron(config, is_dir, expanded),
        svg(move || {
            let c = config.get();
            if is_dir { c.ui_svg(LapceIcons::DIRECTORY_CLOSED) } else { c.file_svg(&icon_path).0 }
        })
        .style(move |s| s.size(14.0, 14.0).margin_right(6.0).flex_shrink(0.0).color(color.unwrap_or_else(|| dim(config)))),
        label(move || name.clone()).style(move |s| {
            let s = s.min_width(0.0).flex_shrink(1.0).text_ellipsis();
            match color {
                Some(c) => s.color(c),
                None => s,
            }
        }),
        label(move || trailing.clone().unwrap_or_default())
            .style(move |s| s.margin_left(6.0).flex_shrink(0.0).color(dim(config))),
    ))
    .on_click_stop(move |_| match &path {
        Some(p) => click.selected_file.set(Some(p.clone())),
        None => click.toggle_file_dir(&key),
    })
    .on_double_click_stop(move |_| {
        if let Some(p) = &double_click_path {
            double_click.open_file_diff(p);
        }
    })
    .debug_name(letter.unwrap_or("dir"))
    .style(move |s| {
        let hovered = config.get().color(LapceColor::PANEL_HOVERED_BACKGROUND);
        let is_selected = for_style.is_some() && selected.get() == for_style;
        s.width_full()
            .height(ROW_HEIGHT)
            .flex_shrink(0.0)
            .items_center()
            .padding_left(8.0 + depth * 16.0)
            .padding_right(8.0)
            .cursor(CursorStyle::Pointer)
            .hover(|s| s.background(hovered))
            .apply_if(is_selected, |s| s.background(tree_selected()))
    })
}

/// Message, then `hash author <email> on date`, who committed it, and its labels.
fn message_block(config: Config, d: GitCommitDetails) -> impl View {
    let info = d.info.clone();
    let hash: String = info.oid.chars().take(8).collect();
    let meta = format!("{hash} {} <{}> on {}", info.author_name, info.author_email, format_time(info.timestamp));
    let committer = (!d.committer_name.is_empty() && d.committer_name != info.author_name)
        .then(|| format!("committed by {} on {}", d.committer_name, format_time(d.commit_timestamp)));
    let labels = {
        let names: Vec<&str> = info
            .refs
            .iter()
            .filter(|r| r.kind != crate::codelitex::git::GitRefKind::Head)
            .map(|r| r.name.as_str())
            .collect();
        (!names.is_empty()).then(|| names.join(", "))
    };
    let message = d.message.clone();

    stack((
        label(move || message.clone()).style(move |s| {
            s.font_family("Menlo, monospace".to_string())
                .font_size(12.5)
                .font_bold()
                .line_height(1.45)
                .color(config.get().color(LapceColor::EDITOR_FOREGROUND))
        }),
        label(move || meta.clone()).style(move |s| s.margin_top(10.0).color(dim(config))),
        label(move || committer.clone().unwrap_or_default())
            .style(move |s| s.color(dim(config)).apply_if(committer_is_none(&d.committer_name, &info.author_name), |s| s.hide())),
        label(move || labels.clone().unwrap_or_default())
            .style(move |s| s.margin_top(6.0).color(green())),
    ))
    .style(|s| s.flex_col().width_full().padding(12.0))
}

fn committer_is_none(committer: &str, author: &str) -> bool {
    committer.is_empty() || committer == author
}
