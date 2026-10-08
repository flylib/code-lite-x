//! The Git history panel: branches | commits | details of the selected commit.
// CodeLiteX: not part of upstream Lapce.

use std::{ops::Range, path::Path, rc::Rc};

use floem::{
    IntoView, View,
    event::EventListener,
    peniko::{
        Color,
        kurbo::{Point, Size},
    },
    reactive::{SignalGet, SignalUpdate, SignalWith, create_rw_signal},
    style::CursorStyle,
    views::{
        Decorators, VirtualVector, container, dyn_stack, empty, label, scroll::scroll,
        stack, svg, virtual_stack,
    },
};

use super::{kind::PanelKind, position::PanelPosition};
use crate::{
    app::clickable_icon,
    codelitex::{
        git::{GitChangedFile, GitCommitDetails, GitCommitInfo, GitRef, GitRefKind},
        git_log::{GitLogData, GitRefLists, change_letter, format_time},
    },
    config::{color::LapceColor, icon::LapceIcons},
    text_input::TextInputBuilder,
    window_tab::{Focus, WindowTabData},
};

const ROW_HEIGHT: f64 = 24.0;
const BRANCHES_WIDTH: f64 = 200.0;
const DETAILS_WIDTH: f64 = 340.0;
const AUTHOR_WIDTH: f64 = 150.0;
const DATE_WIDTH: f64 = 130.0;

pub fn git_log_panel(
    window_tab_data: Rc<WindowTabData>,
    _position: PanelPosition,
) -> impl View {
    let data = window_tab_data.git_log.clone();
    let config = data.common.config;
    let focus = data.common.focus;
    data.ensure_loaded();

    stack((
        toolbar(data.clone()),
        stack((
            branches_pane(data.clone()),
            commits_pane(data.clone()),
            details_pane(data.clone()),
        ))
        .style(|s| s.flex_row().width_full().min_height(0.0).flex_grow(1.0)),
    ))
    .on_event_cont(EventListener::PointerDown, move |_| {
        if focus.get_untracked() != Focus::Panel(PanelKind::GitLog) {
            focus.set(Focus::Panel(PanelKind::GitLog));
        }
    })
    .style(move |s| {
        s.flex_col()
            .size_pct(100.0, 100.0)
            .color(config.get().color(LapceColor::PANEL_FOREGROUND))
    })
    .debug_name("Git Log Panel")
}

fn toolbar(data: GitLogData) -> impl View {
    let config = data.common.config;
    let focus = data.common.focus;
    let cursor_x = create_rw_signal(0.0);
    let is_focused = move || focus.get() == Focus::Panel(PanelKind::GitLog);
    let refresh = data.clone();
    let status = data.clone();

    stack((
        scroll(
            TextInputBuilder::new()
                .is_focused(is_focused)
                .build_editor(data.search.clone())
                .placeholder(|| "Search subject, author or hash".to_string())
                .on_cursor_pos(move |point| cursor_x.set(point.x))
                .style(|s| s.padding_vert(4.0).padding_horiz(10.0).min_width_pct(100.0)),
        )
        .ensure_visible(move || {
            Size::new(20.0, 0.0)
                .to_rect()
                .with_origin(Point::new(cursor_x.get(), 0.0))
        })
        .scroll_style(|s| s.hide_bars(true))
        .style(move |s| {
            let config = config.get();
            s.flex_grow(1.0)
                .min_width(0.0)
                .cursor(CursorStyle::Text)
                .items_center()
                .border(1.0)
                .border_radius(6.0)
                .border_color(config.color(LapceColor::LAPCE_BORDER))
                .background(config.color(LapceColor::EDITOR_BACKGROUND))
        }),
        label(move || {
            if let Some(err) = status.error.get() {
                err
            } else if status.loading.get() {
                "Loading…".to_string()
            } else {
                let n = status.commits.with(|c| c.len());
                format!("{n}{} commits", if status.has_more.get() { "+" } else { "" })
            }
        })
        .style(move |s| {
            s.margin_left(10.0)
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
        clickable_icon(
            || LapceIcons::DEBUG_RESTART,
            move || refresh.refresh(),
            || false,
            || false,
            || "Refresh",
            config,
        )
        .style(|s| s.margin_left(6.0)),
    ))
    .style(move |s| {
        s.width_full()
            .items_center()
            .padding(6.0)
            .border_bottom(1.0)
            .border_color(config.get().color(LapceColor::LAPCE_BORDER))
    })
}

// ----- branches ---------------------------------------------------------------------------

#[derive(Clone, PartialEq)]
enum BranchRow {
    All,
    Header(&'static str),
    Ref { name: String, kind: GitRefKind, is_head: bool },
}

fn branch_rows(lists: &GitRefLists) -> Vec<BranchRow> {
    let mut rows = vec![BranchRow::All];
    let mut section = |title: &'static str, items: Vec<BranchRow>| {
        if !items.is_empty() {
            rows.push(BranchRow::Header(title));
            rows.extend(items);
        }
    };
    section(
        "Local",
        lists
            .local
            .iter()
            .map(|b| BranchRow::Ref { name: b.name.clone(), kind: GitRefKind::LocalBranch, is_head: b.is_head })
            .collect(),
    );
    section(
        "Remote",
        lists
            .remote
            .iter()
            .map(|b| BranchRow::Ref { name: b.name.clone(), kind: GitRefKind::RemoteBranch, is_head: false })
            .collect(),
    );
    section(
        "Tags",
        lists
            .tags
            .iter()
            .map(|t| BranchRow::Ref { name: t.clone(), kind: GitRefKind::Tag, is_head: false })
            .collect(),
    );
    rows
}

fn branches_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    let refs = data.refs;

    container(
        scroll(
            dyn_stack(
                move || refs.with(branch_rows),
                |row| match row {
                    BranchRow::All => "all".to_string(),
                    BranchRow::Header(t) => format!("header:{t}"),
                    BranchRow::Ref { name, kind, is_head } => format!("{kind:?}:{name}:{is_head}"),
                },
                move |row| {
                    let data = data.clone();
                    match row {
                        BranchRow::Header(title) => label(move || title.to_string())
                            .style(move |s| {
                                s.padding_horiz(10.0)
                                    .padding_top(8.0)
                                    .padding_bottom(2.0)
                                    .font_size(11.0)
                                    .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
                            })
                            .into_any(),
                        BranchRow::All => branch_item("All branches".to_string(), None, false, None, data)
                            .into_any(),
                        BranchRow::Ref { name, kind, is_head } => {
                            let filter = Some(name.clone());
                            branch_item(name, filter, is_head, Some(kind), data).into_any()
                        }
                    }
                },
            )
            .style(|s| s.flex_col().width_full()),
        )
        .style(|s| s.size_full()),
    )
    .style(move |s| {
        s.width(BRANCHES_WIDTH)
            .flex_shrink(0.0)
            .height_full()
            .border_right(1.0)
            .border_color(config.get().color(LapceColor::LAPCE_BORDER))
    })
    .debug_name("Git Branches")
}

fn branch_item(
    text: String,
    filter: Option<String>,
    is_head: bool,
    kind: Option<GitRefKind>,
    data: GitLogData,
) -> impl View {
    let config = data.common.config;
    let selected = data.branch;
    let target = filter.clone();
    let marker = if is_head { "● " } else { "" };
    label(move || format!("{marker}{text}"))
        .on_click_stop(move |_| data.set_branch(filter.clone()))
        .style(move |s| {
            let config = config.get();
            s.width_full()
                .height(ROW_HEIGHT)
                .items_center()
                .padding_left(if kind.is_some() { 20.0 } else { 10.0 })
                .padding_right(10.0)
                .text_ellipsis()
                .cursor(CursorStyle::Pointer)
                .apply_if(is_head, |s| s.font_bold())
                .hover(|s| s.background(config.color(LapceColor::PANEL_HOVERED_BACKGROUND)))
                .apply_if(selected.get() == target, |s| {
                    s.background(config.color(LapceColor::PANEL_CURRENT_BACKGROUND))
                })
        })
}

// ----- commits ----------------------------------------------------------------------------

struct CommitItems(im::Vector<GitCommitInfo>);

impl VirtualVector<GitCommitInfo> for CommitItems {
    fn total_len(&self) -> usize {
        self.0.len()
    }

    fn slice(&mut self, range: Range<usize>) -> impl Iterator<Item = GitCommitInfo> {
        self.0.slice(range).into_iter()
    }
}

fn commits_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    let commits = data.commits;
    let loader = data.clone();

    container(
        scroll(
            virtual_stack(
                move || CommitItems(commits.get()),
                |commit| commit.oid.clone(),
                {
                    let data = data.clone();
                    move |commit| commit_row(data.clone(), commit)
                },
            )
            .item_size_fixed(|| ROW_HEIGHT)
            .style(|s| s.flex_col().width_full()),
        )
        .on_scroll(move |rect| {
            // near the end of what is loaded: fetch the next page
            let total = commits.with_untracked(|c| c.len()) as f64 * ROW_HEIGHT;
            if rect.y1 + 10.0 * ROW_HEIGHT >= total {
                loader.load_more();
            }
        })
        .style(|s| s.size_full()),
    )
    .style(move |s| {
        s.flex_grow(1.0)
            .min_width(0.0)
            .height_full()
            .border_right(1.0)
            .border_color(config.get().color(LapceColor::LAPCE_BORDER))
    })
}

fn commit_row(data: GitLogData, commit: GitCommitInfo) -> impl View {
    let config = data.common.config;
    let selected = data.selected;
    let oid = commit.oid.clone();
    let for_style = commit.oid.clone();
    let click = data.clone();
    let author = commit.author_name.clone();
    let when = format_time(commit.timestamp);
    let summary = commit.summary.clone();

    stack((
        ref_badges(commit.refs.clone()),
        label(move || summary.clone())
            .style(|s| s.flex_grow(1.0).min_width(0.0).text_ellipsis()),
        label(move || author.clone()).style(move |s| {
            s.width(AUTHOR_WIDTH)
                .flex_shrink(0.0)
                .padding_left(10.0)
                .text_ellipsis()
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
        label(move || when.clone()).style(move |s| {
            s.width(DATE_WIDTH)
                .flex_shrink(0.0)
                .padding_left(10.0)
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
    ))
    .on_click_stop(move |_| click.select(&oid))
    .style(move |s| {
        let config = config.get();
        s.width_full()
            .height(ROW_HEIGHT)
            .items_center()
            .padding_horiz(10.0)
            .cursor(CursorStyle::Pointer)
            .hover(|s| s.background(config.color(LapceColor::PANEL_HOVERED_BACKGROUND)))
            .apply_if(selected.get().as_deref() == Some(for_style.as_str()), |s| {
                s.background(config.color(LapceColor::PANEL_CURRENT_BACKGROUND))
            })
    })
}

fn ref_color(kind: GitRefKind) -> Color {
    match kind {
        GitRefKind::LocalBranch => Color::from_rgb8(0x6A, 0xAB, 0x73),
        GitRefKind::RemoteBranch => Color::from_rgb8(0x5C, 0x9D, 0xFF),
        GitRefKind::Tag => Color::from_rgb8(0xE5, 0xC0, 0x7B),
        GitRefKind::Head => Color::from_rgb8(0xFF, 0x8A, 0x65),
    }
}

fn ref_badges(refs: Vec<GitRef>) -> impl View {
    dyn_stack(
        move || refs.clone(),
        |r| (r.name.clone(), r.kind as u8),
        |r| {
            let color = ref_color(r.kind);
            let bold = r.is_head;
            label(move || r.name.clone()).style(move |s| {
                s.margin_right(6.0)
                    .padding_horiz(5.0)
                    .height(ROW_HEIGHT - 8.0)
                    .items_center()
                    .flex_shrink(0.0)
                    .font_size(11.0)
                    .border(1.0)
                    .border_radius(4.0)
                    .color(color)
                    .border_color(color.multiply_alpha(0.7))
                    .background(color.multiply_alpha(0.12))
                    .apply_if(bold, |s| s.font_bold())
            })
        },
    )
    .style(|s| s.flex_shrink(0.0))
}

// ----- details ----------------------------------------------------------------------------

fn details_pane(data: GitLogData) -> impl View {
    let config = data.common.config;
    let selected = data.selected;
    let details = data.details;

    container(
        scroll(
            stack((
                label(|| "Select a commit to see its details".to_string()).style(move |s| {
                    s.padding(10.0)
                        .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
                        .apply_if(selected.get().is_some(), |s| s.hide())
                }),
                dyn_stack(
                    move || details.get().into_iter().collect::<Vec<_>>(),
                    |d| match d {
                        Ok(d) => d.info.oid.clone(),
                        Err(e) => e.clone(),
                    },
                    move |d| match d {
                        Ok(d) => commit_details(data.clone(), d).into_any(),
                        Err(e) => label(move || e.clone())
                            .style(|s| s.padding(10.0))
                            .into_any(),
                    },
                )
                .style(|s| s.flex_col().width_full()),
            ))
            .style(|s| s.flex_col().width_full()),
        )
        .style(|s| s.size_full()),
    )
    .style(move |s| {
        s.width(DETAILS_WIDTH)
            .flex_shrink(0.0)
            .height_full()
            .color(config.get().color(LapceColor::PANEL_FOREGROUND))
    })
}

fn detail_line(config: floem::reactive::ReadSignal<std::sync::Arc<crate::config::LapceConfig>>, title: &'static str, text: String) -> impl View {
    stack((
        label(move || title.to_string()).style(move |s| {
            s.width(70.0)
                .flex_shrink(0.0)
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
        label(move || text.clone()).style(|s| s.min_width(0.0).flex_grow(1.0)),
    ))
    .style(|s| s.width_full().padding_horiz(10.0).padding_vert(1.0))
}

fn commit_details(data: GitLogData, d: GitCommitDetails) -> impl View {
    let config = data.common.config;
    let info = d.info.clone();
    let author = format!("{} <{}>  {}", info.author_name, info.author_email, format_time(info.timestamp));
    let committer = (d.committer_email != info.author_email || d.commit_timestamp != info.timestamp)
        .then(|| format!("{} <{}>  {}", d.committer_name, d.committer_email, format_time(d.commit_timestamp)));
    let parents = info.parents.iter().map(|p| p.chars().take(7).collect::<String>()).collect::<Vec<_>>().join(", ");
    let files = d.files.clone();
    let count = files.len();

    stack((
        label(move || d.message.clone()).style(move |s| {
            s.width_full()
                .padding(10.0)
                .line_height(1.5)
                .border_bottom(1.0)
                .border_color(config.get().color(LapceColor::LAPCE_BORDER))
        }),
        detail_line(config, "Hash", info.oid.clone()),
        detail_line(config, "Author", author),
        committer.map(|c| detail_line(config, "Committer", c).into_any()).unwrap_or_else(|| empty().into_any()),
        if parents.is_empty() { empty().into_any() } else { detail_line(config, "Parents", parents).into_any() },
        label(move || format!("{count} changed file{}", if count == 1 { "" } else { "s" })).style(move |s| {
            s.padding_horiz(10.0)
                .padding_top(10.0)
                .padding_bottom(4.0)
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
        dyn_stack(
            move || files.clone(),
            |f| f.path.clone(),
            move |f| changed_file_row(data.clone(), f),
        )
        .style(|s| s.flex_col().width_full()),
    ))
    .style(|s| s.flex_col().width_full().padding_bottom(10.0))
}

fn changed_file_row(data: GitLogData, file: GitChangedFile) -> impl View {
    let config = data.common.config;
    let path = Path::new(&file.path).to_path_buf();
    let icon_path = path.clone();
    let style_path = path.clone();
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let folder = path.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    let letter = change_letter(file.kind);
    let kind = file.kind;
    let renamed_from = file.old_path.clone();

    stack((
        label(move || letter.to_string()).style(move |s| {
            use crate::codelitex::git::GitChangeKind as K;
            let c = config.get();
            let color = match kind {
                K::Added | K::Copied => c.color(LapceColor::SOURCE_CONTROL_ADDED),
                K::Deleted => c.color(LapceColor::SOURCE_CONTROL_REMOVED),
                _ => c.color(LapceColor::SOURCE_CONTROL_MODIFIED),
            };
            s.width(16.0).flex_shrink(0.0).color(color)
        }),
        svg(move || config.get().file_svg(&icon_path).0).style(move |s| {
            let config = config.get();
            let size = config.ui.icon_size() as f32;
            s.min_width(size)
                .size(size, size)
                .margin_right(6.0)
                .apply_opt(config.file_svg(&style_path).1, |s, c| s.color(c))
        }),
        label(move || name.clone()).style(|s| s.flex_shrink(0.0).margin_right(6.0)),
        label(move || match &renamed_from {
            Some(old) => format!("{folder}  ← {old}"),
            None => folder.clone(),
        })
        .style(move |s| {
            s.min_width(0.0)
                .text_ellipsis()
                .color(config.get().color(LapceColor::PANEL_FOREGROUND_DIM))
        }),
    ))
    .style(move |s| {
        s.width_full()
            .height(ROW_HEIGHT)
            .items_center()
            .padding_horiz(10.0)
            .hover(|s| s.background(config.get().color(LapceColor::PANEL_HOVERED_BACKGROUND)))
    })
}
