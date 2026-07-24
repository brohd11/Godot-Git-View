extends VBoxContainer

## The sidebar's Git section — a view over GitService.
##
## Holds no git state of its own: it renders GitService's status/commits/repos and pushes user
## actions (repo select, stage/discard) back to it. GitService runs the git calls off the main thread
## and publishes `status_updated` / `commits_updated` / `repos_updated`, which drive the branch info,
## the Changes list and the Commits list.

const UtilsRemote = preload("res://addons/git_view/src/util/utils_remote.gd")
const UControl = UtilsRemote.UControl
const TabBarContainer = UtilsRemote.TabBarContainer
const RightClickHandler = UtilsRemote.RightClickHandler
const Options = UtilsRemote.Options

const UtilsLocal = preload("res://addons/git_view/src/util/utils_local.gd")

const GitUtil = UtilsRemote.GitUtil
const ChangeList = preload("res://addons/git_view/src/panel/change_list.gd")
const CommitList = preload("res://addons/git_view/src/panel/commit_list.gd")

const MAIN_REPO = "res://"
const MAIN_REPO_TITLE = "Project"

var right_click_handler:RightClickHandler

var repo_popup_button:Button
var repo_label:Label
var top_row:HBoxContainer
var branch_hbox:HBoxContainer
var branch_texture:TextureRect
var branch_label:Label
var divergence_label:Label
var tab_container:TabBarContainer
var change_list:ChangeList
var commit_list:CommitList

# the shared data provider — bound in _ready, the source of every value rendered here
var _git:GitService

var _dock_data:Dictionary
var _initialized:=false


func get_dock_data() -> Dictionary:
	return {
		Keys.CURRENT_REPO: _git.current_repo if is_instance_valid(_git) else MAIN_REPO,
		Keys.CURRENT_TAB: tab_container.get_tab_bar().current_tab,
	}


## Arrives after _ready — the nodes already exist, so apply straight away.
func set_dock_data(data:Dictionary) -> void:
	_dock_data = data
	_apply_dock_data()


func _ready() -> void:
	right_click_handler = RightClickHandler.new()
	add_child(right_click_handler)
	
	top_row = HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(top_row)
	
	repo_popup_button = Button.new()
	repo_popup_button.theme_type_variation = &"FlatButton"
	repo_popup_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	repo_popup_button.icon = EditorInterface.get_editor_theme().get_icon(&"TexturePreviewChannels", &"EditorIcons")
	repo_popup_button.pressed.connect(_on_repo_popup_pressed)
	top_row.add_child(repo_popup_button)
	
	repo_label = Label.new()
	repo_label.text = MAIN_REPO_TITLE
	repo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_row.add_child(repo_label)
	repo_label.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())
	
	
	#branch_row.add_spacer(false)
	top_row.add_child(VSeparator.new())
	
	branch_hbox = HBoxContainer.new()
	top_row.add_child(branch_hbox)
	
	branch_texture = TextureRect.new()
	branch_texture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	branch_texture.texture = EditorInterface.get_editor_theme().get_icon(&"VcsBranches", &"EditorIcons")
	branch_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_texture)

	# the branch name gives way: ellipsis trims the end of a string, so a combined label would eat the divergence — the half worth acting on
	branch_label = Label.new()
	#branch_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	#branch_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	branch_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	branch_hbox.add_child(branch_label)
	branch_label.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())

	divergence_label = Label.new()
	branch_hbox.add_child(divergence_label)

	tab_container = TabBarContainer.new()
	add_child(tab_container)
	UControl.expand(tab_container)
	
	change_list = ChangeList.new()
	change_list.name = "Changes"
	change_list.changes_command.connect(_on_changes_command)
	tab_container.add_tab(change_list)
	change_list.right_click_handler = right_click_handler
	UtilsLocal.set_item_list_sb(change_list)

	commit_list = CommitList.new()
	commit_list.name = "Commits"
	tab_container.add_tab(commit_list)
	UtilsLocal.set_item_list_sb(commit_list)

	# the change list looks its status texture up at draw time, so a bake landing later only needs a
	# repaint — the rows themselves are already right
	var glyph_icons = GitService.get_glyph_icons_node()
	if is_instance_valid(glyph_icons):
		glyph_icons.generated.connect(change_list.queue_redraw)

	# GitService is registered by ScriptDock before the sidebar is built, so it is ready here
	_bind_service()

	if not _initialized:
		_apply_dock_data()


func _bind_service() -> void:
	_git = GitService.get_instance()
	if not is_instance_valid(_git):
		# nothing to render against; a later status/repos change would emit into a dead panel anyway
		return

	_git.status_updated.connect(_on_status_updated)
	_git.commits_updated.connect(_on_commits_updated)
	_git.repos_updated.connect(_on_repos_updated)

	# the service may have scanned before this panel existed — render whatever it already holds
	_on_repos_updated()
	if not _git.status.is_empty():
		_on_status_updated(_git.current_repo)
	if not _git.commits.is_empty():
		_on_commits_updated(_git.current_repo)


func _apply_dock_data() -> void:
	tab_container.set_current_tab(int(_dock_data.get(Keys.CURRENT_TAB, 0)))
	var saved_repo:String = _dock_data.get(Keys.CURRENT_REPO, MAIN_REPO)
	_dock_data = {}

	# restore the selected repo through the service; set_repo no-ops if it is already current
	if is_instance_valid(_git) and saved_repo != _git.current_repo and saved_repo in _git.repos:
		_clear_lists() # don't leave the default repo's rows up while the restored repo's calls run
		_git.set_repo(saved_repo)

	_initialized = true


func clean_up() -> void:
	if not is_instance_valid(_git):
		return
	# the service outlives this panel, so drop these connections rather than let it emit into a freed node
	if _git.status_updated.is_connected(_on_status_updated):
		_git.status_updated.disconnect(_on_status_updated)
	if _git.commits_updated.is_connected(_on_commits_updated):
		_git.commits_updated.disconnect(_on_commits_updated)
	
	#if _git.repos_updated.is_connected(_on_repos_updated):
		#_git.repos_updated.disconnect(_on_repos_updated)


func _on_repos_updated() -> void:
	return


func _on_repo_popup_pressed():
	var options = Options.new()
	for repo in _git.repos:
		options.add_option("Repo/" + _get_repo_name(repo), _select_repo.bind(repo))
	
	right_click_handler.display_on_control(options, repo_popup_button, Vector2(0, repo_popup_button.size.y))

func _select_repo(repo_dir:String):
	if _git.current_repo == repo_dir:
		return
	# don't leave the old repo's rows up while the new repo's git calls run — the branch least of all
	_clear_lists()
	_git.set_repo(repo_dir)

func _get_repo_name(repo_dir:String):
	return MAIN_REPO_TITLE if repo_dir == MAIN_REPO else repo_dir.trim_suffix("/").get_file()

# Don't leave one repo's rows up while another's data is in flight — the old branch under the new
# repo's name is a worse lie than showing nothing.
func _clear_lists() -> void:
	# through set_files, not clear(): the rows and the status dict behind them go together, and a
	# menu built off a dict the rows no longer match is the one thing this must never do
	change_list.set_files([])
	commit_list.clear_commits()

	branch_label.text = ""
	divergence_label.hide()
	top_row.tooltip_text = ""


func _on_status_updated(_repo_dir:String) -> void:
	_rebuild_change_list()
	_update_repo_info()


# Spawns nothing: reads the status and log GitService already fetched — it assigns both members
# before emitting either signal, so `commits` here is not a frame behind.
func _update_repo_info() -> void:
	var info = GitUtil.get_repo_info(_git.status, _git.commits)
	var branch:Dictionary = info[GitUtil.Keys.BRANCH]
	
	repo_label.text = _get_repo_name(_git.current_repo)

	#branch_label.text = GitUtil.get_branch_label(branch)
	branch_label.text = branch.get(GitUtil.Keys.BRANCH_NAME)
	branch_hbox.tooltip_text = GitUtil.format_repo_tooltip(info)

	var divergence = GitUtil.get_divergence_label(branch)
	divergence_label.text = divergence
	divergence_label.visible = not divergence.is_empty()

	# behind means there is something to pull, which is the one that wants noticing
	if not divergence.is_empty():
		divergence_label.add_theme_color_override(&"font_color",
			GitUtil.Colors.L_YELLOW if branch[GitUtil.Keys.BRANCH_BEHIND] > 0
			else GitUtil.Colors.L_GREEN)

	


func _on_commits_updated(_repo_dir:String) -> void:
	_rebuild_commit_list()


func _rebuild_change_list() -> void:
	if not is_instance_valid(_git):
		return
	
	var files:Dictionary = _git.status.get(GitUtil.Keys.FILES, {})
	var paths = files.keys()
	paths.sort()
	# the dict travels with the rows: it is what decides which commands a selection is offered, and
	# it has to be the same snapshot the command's pathspecs are built from
	change_list.set_files(paths, files, _git.current_repo)


func _rebuild_commit_list() -> void:
	commit_list.clear_commits()
	# git already returned these newest first — do not sort
	for commit in _git.commits:
		commit_list.add_commit(commit)


func _on_changes_command(command:GitUtil.Command, paths:Array):
	_git.run_command(command, paths)


class Keys:
	const CURRENT_REPO = &"git_panel.current_repo"
	const CURRENT_TAB = &"git_panel.current_tab"
