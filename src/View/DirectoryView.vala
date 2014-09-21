/*
 Copyright (C) 2014 ELementary Developers

 This program is free software: you can redistribute it and/or modify it
 under the terms of the GNU Lesser General Public License version 3, as published
 by the Free Software Foundation.

 This program is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY; without even the implied warranties of
 MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
 PURPOSE. See the GNU General Public License for more details.

 You should have received a copy of the GNU General Public License along
 with this program. If not, see <http://www.gnu.org/licenses/>.

 Authors : Jeremy Wootten <jeremy@elementary.org>
*/

/** Implementations of DirectoryView are
 * IconView
 * ListView
 * ColumnView
**/
   
namespace FM {
    public abstract class DirectoryView : Gtk.ScrolledWindow {
        public enum TargetType {
            STRING,
            TEXT_URI_LIST,
            XDND_DIRECT_SAVE0,
            NETSCAPE_URL
        }

        const int MAX_TEMPLATES = 32;

        const Gtk.TargetEntry [] drag_targets = {
            {"text/plain", Gtk.TargetFlags.SAME_APP, TargetType.STRING},
            {"text/uri-list", Gtk.TargetFlags.SAME_APP, TargetType.TEXT_URI_LIST}
        };

        const Gtk.TargetEntry [] drop_targets = {
            {"text/uri-list", Gtk.TargetFlags.SAME_APP, TargetType.TEXT_URI_LIST},
            {"XdndDirectSave0", Gtk.TargetFlags.SAME_APP, TargetType.TEXT_URI_LIST},
            {"_NETSCAPE_URL", Gtk.TargetFlags.SAME_APP, TargetType.TEXT_URI_LIST}
        };

        const Gdk.DragAction file_drag_actions = (Gdk.DragAction.COPY | Gdk.DragAction.MOVE | Gdk.DragAction.LINK);

        /* Menu Handling */
        const GLib.ActionEntry [] selection_entries = {
            {"open", on_selection_action_open_executable},
            {"open_with_app", on_selection_action_open_with_app, "s"},
            {"open_with_default", on_selection_action_open_with_default},
            {"open_with_other_app", on_selection_action_open_with_other_app},
            {"rename", on_selection_action_rename},
            {"cut", on_selection_action_cut},
            {"trash", on_selection_action_trash},
            {"delete", on_selection_action_delete},
            {"restore", on_selection_action_restore}
        };

        GLib.SimpleActionGroup selection_actions;

        const GLib.ActionEntry [] background_entries = {
            {"new", on_background_action_new, "s"},
            {"create_from", on_background_action_create_from, "s"},
            {"sort_by", on_background_action_sort_by_changed, "s", "'name'"},
            {"reverse", on_background_action_reverse_changed, null, "false"},
            {"show_hidden", null, null, "false", change_state_show_hidden}
        };

        GLib.SimpleActionGroup background_actions;

        const GLib.ActionEntry [] common_entries = {
            {"copy", on_common_action_copy},
            {"paste_into", on_common_action_paste_into},
            {"open_in", on_common_action_open_in, "s"},
            {"bookmark", on_common_action_bookmark},
            {"properties", on_common_action_properties}
        };

        GLib.SimpleActionGroup common_actions;

        private Marlin.ZoomLevel _zoom_level;
        public Marlin.ZoomLevel zoom_level {
            get {
                return _zoom_level;
            }

            set {
                if (value <= maximum_zoom &&
                    value >= minimum_zoom &&
                    value != _zoom_level) {
                        _zoom_level = value;
                        on_zoom_level_changed (value);
                }
            }
        }

        public int icon_size {
            get {
                return Marlin.zoom_level_to_icon_size (_zoom_level);
            }
        }

        protected Marlin.ZoomLevel minimum_zoom = Marlin.ZoomLevel.SMALLEST; 
        protected Marlin.ZoomLevel maximum_zoom = Marlin.ZoomLevel.LARGEST; 

        /* drag support */
        unowned GLib.List<unowned GOF.File> drag_file_list = null;
        uint drag_scroll_timer_id = 0;
        uint drag_timer_id = 0;
        int drag_x = 0;
        int drag_y = 0;
        protected int drag_delay = Gtk.Settings.get_default ().gtk_menu_popup_delay;
        GOF.File? drop_target_file = null;
        Gdk.DragAction current_suggested_action = Gdk.DragAction.DEFAULT;
        Gdk.DragAction current_actions = Gdk.DragAction.DEFAULT;

        /* drop site support */
        private bool drop_data_ready = false; /* whether the drop data was received already */
        bool _drop_highlight;
        bool drop_highlight {
            get {
                return _drop_highlight;
            }

            set {
                if (value != _drop_highlight) {
                    if (value)
                        Gtk.drag_highlight (this);
                    else 
                        Gtk.drag_unhighlight (this);
                }
                _drop_highlight = value;
            }
        }

        private bool drop_occurred = false; /* whether the data was dropped */
        private GLib.List<GLib.File> drop_file_list = null; /* the list of URIs that are contained in the drop data */
        private bool drag_has_begun = false;
        protected bool dnd_disabled = false;
        private void* drag_data;

        /* support for generating thumbnails */
        Marlin.Thumbnailer thumbnailer = null;
        uint thumbnail_request = 0;
        uint thumbnail_source_id = 0;

        private GLib.List<GLib.AppInfo> open_with_apps;
        private GLib.AppInfo default_app;
        private GLib.List<unowned GOF.File>? templates = null;

        /* TODO Support for preview */
        private string? previewer = null;

        /* Rename support */
        protected Gtk.TreeViewColumn name_column;
        protected Gtk.CellRendererText name_renderer;
        protected Gtk.Entry? editable_widget = null;
        public string original_name = "";

        /* Support for zoom by smooth scrolling */
        private double total_delta_y = 0.0;

        protected GLib.List<GOF.Directory.Async>? loaded_subdirectories = null;
        protected GLib.List<unowned GOF.File> selected_files = null ;
        private Gtk.TreePath selection_before_delete;
        private bool selection_was_removed = false;
        public bool select_added_files = false;
        protected bool renaming = false;
        private bool updates_frozen = false;
        private bool in_trash = false;
        protected bool is_loading;
        protected bool helpers_shown;

        private Gtk.Widget view;
        private unowned Marlin.ClipboardManager clipboard;
        protected FM.ListModel model;
        protected Marlin.IconRenderer icon_renderer; 
        protected unowned Marlin.View.Slot slot; /* prevent circular references */
        protected unowned Marlin.View.Window window; /*For convenience - this can be derived from slot */
        protected static DndHandler dnd_handler = new FM.DndHandler ();
        private Gtk.TreePath? hover_path = null;

        public signal void path_change_request (GLib.File location, int flag = 0, bool new_root = true);

/*** Creation methods */
        public DirectoryView (Marlin.View.Slot _slot) {
//message ("new directory view - location %s", _slot.directory.file.uri);
            slot = _slot;
            window = _slot.window;
            clipboard = ((Marlin.Application)(window.application)).get_clipboard_manager ();
            icon_renderer = new Marlin.IconRenderer ();
            name_renderer = new Gtk.CellRendererText ();
            thumbnailer = Marlin.Thumbnailer.get ();
            model = GLib.Object.@new (FM.ListModel.get_type (), null) as FM.ListModel;

            set_up__menu_actions ();
            set_up_directory_view ();

            view = create_view (); /* Abstract */
            if (view != null) {
                add (view);
                show_all ();
                connect_drag_drop_signals (view);
                view.add_events (Gdk.EventMask.POINTER_MOTION_MASK);
                view.motion_notify_event.connect (on_motion_notify_event);
                view.leave_notify_event.connect (on_leave_notify_event);
            }
            freeze_tree ();
            set_up_zoom_level ();
            zoom_level_changed (); /* set icon_renderer properties */
        }

        ~DirectoryView () {
//message ("DV  destructor");
            loaded_subdirectories.@foreach ((dir) => {
                remove_subdirectory (dir);
            });
        }

        private void set_up_directory_view () {
//message ("Set up Directory viewt");
            set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
            set_shadow_type (Gtk.ShadowType.NONE);
            /* TODO previewer support */

            size_allocate.connect_after (on_size_allocate);
            button_press_event.connect (on_button_press_event);
            popup_menu.connect (on_popup_menu);
            unrealize.connect (() => {
                clipboard.changed.disconnect (on_clipboard_changed);
            });
            realize.connect (() => {
                clipboard.changed.connect (on_clipboard_changed);
                on_clipboard_changed ();
            });

            scroll_event.connect (on_scroll_event);           

            get_vadjustment ().value_changed.connect ((alloc) => {
//message ("vadjustment changed");
                schedule_thumbnail_timeout ();
            });

            (GOF.Preferences.get_default ()).notify["show-hidden-files"].connect (on_show_hidden_files_changed);
            (GOF.Preferences.get_default ()).notify["interpret-desktop-files"].connect (on_interpret_desktop_files_changed);

            connect_directory_handlers (slot.directory);

            model.row_deleted.connect (on_row_deleted);
            model.row_deleted.connect_after (after_restore_selection);

            model.sort_column_changed.connect (on_sort_column_changed);
            model.set_sort_column_id (slot.directory.file.sort_column_id, slot.directory.file.sort_order);

        }

        private void set_up__menu_actions () {
//message ("set up menu actions");
            selection_actions = new GLib.SimpleActionGroup ();
            selection_actions.add_action_entries (selection_entries, this);
            insert_action_group ("selection", selection_actions);

            background_actions = new GLib.SimpleActionGroup ();
            background_actions.add_action_entries (background_entries, this);
            insert_action_group ("background", background_actions);

            common_actions = new GLib.SimpleActionGroup ();
            common_actions.add_action_entries (common_entries, this);
            insert_action_group ("common", common_actions);

            action_set_state (background_actions, "show_hidden", Preferences.settings.get_boolean ("show-hiddenfiles"));
        }

        public void zoom_in () {
                zoom_level = zoom_level + 1;
        }

        public void zoom_out () {
                zoom_level = zoom_level - 1;
        }

        private void set_up_zoom_level () {
//message ("DV set up zoom level");
            zoom_level = get_set_up_zoom_level (); /* Abstract */
            model.set_property ("size", icon_size);
        }

        public void zoom_normal () {
//message ("zoom normal");
            zoom_level = get_normal_zoom_level (); /* Abstract */
        }

        public void select_first_for_empty_selection () {
            if (selected_files == null) {
//message ("select first for empty selection");
                set_cursor (new Gtk.TreePath.from_indices (0), false, true, true);
            }
        }

        public void select_glib_files (GLib.List<GLib.File> location_list) {
//message ("select glib files");
            updates_frozen = true;
            unselect_all ();
            location_list.@foreach ((location) => {
                var iter = Gtk.TreeIter ();
                GOF.File file = GOF.File.@get (location);
                if (model.get_first_iter_for_file (file, out iter)) {
                        Gtk.TreePath path = model.get_path (iter);
                    if (path != null) {
                        scroll_to_cell (path, null, false);
                        select_path (path);
                    } 
                } 
            });
            updates_frozen = false;
            update_selected_files ();
            notify_selection_changed ();
        }

        public unowned GLib.List<GLib.AppInfo> get_open_with_apps () {
            return open_with_apps;
        }

        public unowned GLib.AppInfo get_default_app () {
//message ("get default app");
            return default_app;
        }

        public void set_updates_frozen (bool freeze) {
//message ("set updates frozen %s", freeze ? "true" : "false");
            if (freeze && !updates_frozen)
                freeze_updates ();
            else if (!freeze && updates_frozen)
                unfreeze_updates ();
        }

        public bool get_updates_frozen () {
            return updates_frozen;
        }

        protected void freeze_updates () {
//message ("DV freeze updates");
            
            updates_frozen = true;
            slot.directory.freeze_update = true;
            action_set_enabled (selection_actions, "cut", false);
            action_set_enabled (common_actions, "copy", false);
            action_set_enabled (common_actions, "paste_into", false);
            action_set_enabled (window.win_actions, "select_all", false);

            size_allocate.disconnect (on_size_allocate);
            clipboard.changed.disconnect (on_clipboard_changed);
            view.motion_notify_event.disconnect (on_motion_notify_event);
            /* TODO queue file changed/added/.. and freeze their updates */

            name_renderer.@set ("editable", true, null);
        }

        protected void unfreeze_updates () {
//message ("DV unfreeze updates");
            if (renaming)
                return;

            updates_frozen = false;
            slot.directory.freeze_update = false;;
            update_menu_actions ();
            size_allocate.connect (on_size_allocate);
            clipboard.changed.connect (on_clipboard_changed);
            view.motion_notify_event.connect (on_motion_notify_event);

            name_renderer.@set ("editable", false, null);

        }

        public new void grab_focus () {
//message ("DV grab focus");
            (this as Gtk.Bin).get_child ().grab_focus ();
        }

        public unowned GLib.List<unowned GOF.File> get_selected_files () {
            return selected_files;
        }

        public bool is_frozen () {
//message ("is_frozen");
            return updates_frozen;
        }
 

/*** Protected Methods */
        protected void set_active_slot () {
//message ("DV set_active");
            slot.active ();
        }

        protected void load_location (GLib.File location) {
//message ("load location");
            /* In column view, this will nest new location in slot.
            /* Else same effect as load_root_location */
            path_change_request (location, Marlin.OpenFlag.DEFAULT, false);
        }

        protected void load_root_location (GLib.File location) {
//message ("load root location");
            path_change_request (location, Marlin.OpenFlag.DEFAULT, true);
        }

    /** Operations on selections */
        protected void activate_selected_items (Marlin.OpenFlag flag = Marlin.OpenFlag.DEFAULT) {
//message ("activate selected items");
            if (updates_frozen || in_trash)
                return;

            unowned GLib.List<unowned GOF.File> selection = get_selected_files ();
            uint nb_elem = selection.length ();
            if (nb_elem < 1)
                return;

            unowned Gdk.Screen screen = Eel.gtk_widget_get_screen (this);
            bool only_folders = selection_only_contains_folders (selection);
            if (nb_elem < 10 && (default_app == null || only_folders)) {
                /* launch each selected file individually ignoring selections greater than 10 */
                bool only_one_file = (nb_elem == 1);
                foreach (unowned GOF.File file in selection) {
                    /* Prevent too rapid activation of files - causes New Tab to crash for example */
                    GLib.Timeout.add (50, () => {
                        activate_file (file, screen, flag, only_one_file);
                        return false;
                    });
                }
            } else if (default_app != null)
                open_files_with (default_app, selection);
        }

        /** Only call with non null selection */
        protected void preview_selected_items () {
            if (previewer == null)  /* At present this is the case! */
                activate_selected_items (Marlin.OpenFlag.DEFAULT);
            else {
                unowned GLib.List<unowned GOF.File> selection = get_selected_files ();
                Gdk.Screen screen = Eel.gtk_widget_get_screen (this);
                GLib.List<GLib.File> location_list = null;
                GOF.File file = selection.data; /* FIXME Can only preview one file */
                location_list.prepend (file.location);
                Gdk.AppLaunchContext context = screen.get_display ().get_app_launch_context ();
                try {
                    GLib.AppInfo previewer_app = GLib.AppInfo.create_from_commandline (previewer, null, 0);
                    previewer_app.launch (location_list, context as GLib.AppLaunchContext);
                } catch (GLib.Error error) {
                    Eel.show_error_dialog (_("Failed to preview"), error.message, null);
                }
            }
        }

        protected void select_gof_file (GOF.File file) {
//message ("select gof file");
            var iter = Gtk.TreeIter ();
            if (!model.get_first_iter_for_file (file, out iter))
                return; /* file not in model */

            var path = model.get_path (iter);
            set_cursor (path, false, true, false);
        }

        protected void add_gof_file_to_selection (GOF.File file) {
//message ("add gof file to selection");
            var iter = Gtk.TreeIter ();
            if (!model.get_first_iter_for_file (file, out iter))
                return; /* file not in model */

            var path = model.get_path (iter);
            select_path (path);
        }

        protected void after_restore_selection (Gtk.TreePath path) {
//message ("after restore selection");
            /* Check if there was only one file selected before the row was deleted. The
             * selection_before_delete is set by on_row_deleted() if this is the case.
             * place the cursor on the selected path */
            set_cursor (selection_before_delete, false, true, false);
            selection_before_delete = null;
        }

    /** Directory signal handlers. */
        /* Signal could be from subdirectory as well as slot directory */
        protected void connect_directory_handlers (GOF.Directory.Async dir) {
            assert (dir != null);
            dir.file_loaded.connect (on_directory_file_loaded);
            dir.file_added.connect (on_directory_file_added);
            dir.file_changed.connect (on_directory_file_changed);
            dir.file_deleted.connect (on_directory_file_deleted);
            dir.icon_changed.connect (on_directory_file_icon_changed);
            dir.done_loading.connect (on_directory_done_loading);
            dir.thumbs_loaded.connect (on_directory_thumbs_loaded);
        }

        protected void disconnect_directory_handlers (GOF.Directory.Async dir) {
            /* If the directory is still loading the file_loaded signal handler
            /* will not have been disconnected */
            if (dir.is_loading ()) {
                dir.file_loaded.disconnect (on_directory_file_loaded);
                dir.cancel ();
            }

            dir.file_added.disconnect (on_directory_file_added);
            dir.file_changed.disconnect (on_directory_file_changed);
            dir.file_deleted.disconnect (on_directory_file_deleted);
            dir.icon_changed.disconnect (on_directory_file_icon_changed);
            dir.done_loading.disconnect (on_directory_done_loading);
            dir.thumbs_loaded.disconnect (on_directory_thumbs_loaded);
        }

        public void change_directory (GOF.Directory.Async old_dir, GOF.Directory.Async new_dir) {
//message ("DV change directory");
            freeze_tree ();
            disconnect_directory_handlers (old_dir);
            block_model ();
            loaded_subdirectories.@foreach ((dir) => {
                remove_subdirectory (dir);
            });
            loaded_subdirectories = null;
            model.clear ();
            unblock_model ();
            connect_directory_handlers (new_dir);
            update_menu_actions ();
            model.set_sort_column_id (slot.directory.file.sort_column_id, slot.directory.file.sort_order);
        }

        public void reload () {
//message ("DV reload");
            change_directory (slot.directory, slot.directory);
        }

        protected void connect_drag_drop_signals (Gtk.Widget widget) {
//message ("connect drag drop");

            /* Set up as drop site */
            Gtk.drag_dest_set (widget, Gtk.DestDefaults.MOTION, drop_targets, Gdk.DragAction.ASK | file_drag_actions);
            widget.drag_drop.connect (on_drag_drop);
            widget.drag_data_received.connect (on_drag_data_received);
            widget.drag_leave.connect (on_drag_leave);
            widget.drag_motion.connect (on_drag_motion);

            /* Set up as drag source */
            Gtk.drag_source_set (widget, Gdk.ModifierType.BUTTON1_MASK, drag_targets, file_drag_actions);
            widget.drag_begin.connect (on_drag_begin);
            widget.drag_data_get.connect (on_drag_data_get);
            widget.drag_data_delete.connect (on_drag_data_delete);
            widget.drag_end.connect (on_drag_end);
        }

        protected void cancel_drag_timer () {
//message ("cancel drag timer");
            if (drag_timer_id > 0) {
                disconnect_drag_timeout_motion_and_release_events ();
                GLib.Source.remove (drag_timer_id);
                drag_timer_id = 0;
            }
        }

        protected void cancel_drag_scroll_timer () {
            if (drag_scroll_timer_id > 0) {
                GLib.Source.remove (drag_scroll_timer_id);
                drag_scroll_timer_id = 0;
            }
        }

        protected void cancel_thumbnailing () {
            if (thumbnail_source_id > 0) {
                GLib.Source.remove (thumbnail_source_id);
                thumbnail_source_id = 0;
            }

            if (thumbnail_request > 0) {
                thumbnailer.dequeue (thumbnail_request);
                thumbnail_request = 0;
            }
        }

        protected void remove_timers () {
            cancel_drag_timer ();
            cancel_drag_scroll_timer ();
        }

        protected bool is_drag_pending () {
//message ("is drag pending");
            return drag_has_begun;
        }

        protected bool selection_only_contains_folders (GLib.List<unowned GOF.File> list) {
            bool only_folders = true;
            list.@foreach ((file) => {
                if (!file.is_folder ())
                    only_folders = false;
            });
            return only_folders;
        }

    /** Handle scroll events */
        protected bool handle_scroll_event (Gdk.EventScroll event) {
            if (updates_frozen)
                return true;

            if ((event.state & Gdk.ModifierType.CONTROL_MASK) > 0) {
                switch (event.direction) {
                    case Gdk.ScrollDirection.UP:
                        zoom_in ();
                        return true;

                    case Gdk.ScrollDirection.DOWN:
                        zoom_out ();
                        return true;

                    case Gdk.ScrollDirection.SMOOTH:
                        double delta_x, delta_y;
                        event.get_scroll_deltas (out delta_x, out delta_y);
                        /* try to emulate a normal scrolling event by summing deltas.
                         * step size of 0.5 chosen to match sensitivity */
                        total_delta_y += delta_y;

                        if (total_delta_y >= 0.5) {
                            total_delta_y = 0;
                            zoom_out ();
                        } else if (total_delta_y <= -0.5) {
                            total_delta_y = 0;
                            zoom_in ();
                        }
                        return true;
                    default:
                        break;
                }
            } 
            return false;
        }

        protected void show_or_queue_context_menu (Gdk.Event event) {
            if (selected_files != null)
                queue_context_menu (event);
            else
                show_context_menu (event);
        }

        protected unowned GLib.List<unowned GOF.File> get_selected_files_for_transfer () {
//message ("get selected files for transfer");
            unowned GLib.List<unowned GOF.File> list = null;
            selected_files.@foreach ((file) => {
                list.prepend (file);
            });

            return list;
        }

/*** Private methods */
    /** File operations */
        private void activate_file (GOF.File file, Gdk.Screen? screen, Marlin.OpenFlag flag, bool only_one_file) {
            if (updates_frozen || in_trash)
                return;

//message ("activate file %s", file.uri);
            GLib.File location = file.location.dup ();
            if (screen == null)
                screen = Eel.gtk_widget_get_screen (this);

            if (file.is_folder ()) {
                switch (flag) {
                    case Marlin.OpenFlag.NEW_TAB:
                        window.add_tab (location, Marlin.ViewMode.CURRENT);
                        break;
                    case Marlin.OpenFlag.NEW_WINDOW:
                        window.add_window(location, Marlin.ViewMode.CURRENT);
                        break;
                    default:
                        if (only_one_file)
                            load_location (location);
                        break;
                }
            } else if (only_one_file && file.is_root_network_folder ())
                load_location (location);
            else if (only_one_file && file.is_executable ())
                file.execute (screen, null, null);
            else if (only_one_file && default_app != null)
                file.open_single (screen, default_app);
            else
                warning ("Unable to activate this file.  Default app is %s", default_app != null ? default_app.get_name () : "null");
        }

        private void trash_or_delete_files (GLib.List<unowned GOF.File> file_list, bool delete_if_already_in_trash) {
            GLib.List<GLib.File> locations = null;
            file_list.@foreach ((file) => {
                locations.prepend (file.location);
            });
            if (locations != null) {
                locations.reverse ();
                Marlin.FileOperations.trash_or_delete (locations,
                                                       window as Gtk.Window,
                                                       (void*) after_trash_or_delete,
                                                       null);
            }
        }

        private void add_file (GOF.File file, GOF.Directory.Async dir) {
            model.add_file (file, dir);
            if (select_added_files)
                add_gof_file_to_selection (file);
        }

        private void new_empty_file (string? parent_uri = null) {
            if (parent_uri == null)
                parent_uri = slot.directory.file.uri;

            Marlin.FileOperations.new_file (this as Gtk.Widget,
                                            null,
                                            parent_uri,
                                            null,
                                            null,
                                            0,
                                            (Marlin.CreateCallback?) create_file_done,
                                            this);
        }

        private void new_empty_folder () {
            Marlin.FileOperations.new_folder (null, null, slot.location, (Marlin.CreateCallback?) create_file_done, this);
        }

        protected void rename_file (GOF.File file_to_rename) {
//message ("rename file");
            unselect_all ();
            select_gof_file (file_to_rename);
            start_renaming_file (file_to_rename, false);
        }


/** File operation callbacks */
        static void create_file_done (GLib.File? new_file, void* data) {
            if (new_file == null)
                return;

            var view = (FM.DirectoryView)data;
            var file_to_rename = GOF.File.@get (new_file);
            /* Allow time for the file to appear in the tree model before renaming */
            GLib.Timeout.add (50, () => {
                view.rename_file (file_to_rename);
                return false;
            });
        }

        private void after_trash_or_delete (GLib.HashTable? debuting_files, bool user_cancel, void* data) {
//message ("after trash or delete");
            if (user_cancel) {
                selection_was_removed = false;
            }
        }

        private void trash_or_delete_selected_files () {
        /* This might be rapidly called multiple times for the same selection
         * when using keybindings. So we remember if the current selection
         * was already removed (but the view doesn't know about it yet).
         */
            if (!selection_was_removed) {
                 unowned GLib.List<unowned GOF.File> selection = get_selected_files_for_transfer ();
                if (selection != null) {
                    selection_was_removed = true;
                    trash_or_delete_files (selection, true);
                }
            }
        }


        private void delete_selected_files () {
             unowned GLib.List<unowned GOF.File> selection = get_selected_files_for_transfer ();
            if (selection == null)
                return;

            GLib.List<GLib.File> locations = null;
            selection.@foreach ((file) => {
                locations.prepend (file.location);
            });
            locations.reverse ();
            Marlin.FileOperations.@delete (locations, window as Gtk.Window, null, null);
        }

/** Signal Handlers */

    /** Menu actions */
        /** Selection actions */

        private void on_selection_action_rename (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on selection action rename");
            /* TODO invoke batch renamer */
            if (selected_files.next != null)
                warning ("Cannot rename multiple files (yet) - renaming first only");

            var file = selected_files.first ().data;
            bool preselect_whole_name = file.is_folder ();

            start_renaming_file (file, preselect_whole_name);
        }

        private void on_selection_action_cut (GLib.SimpleAction action, GLib.Variant? param) {
            unowned GLib.List<unowned GOF.File> selection = get_selected_files_for_transfer ();
            clipboard.cut_files (selection);
        }

        private void on_selection_action_trash (GLib.SimpleAction action, GLib.Variant? param) {
            trash_or_delete_selected_files ();
        }

        private void on_selection_action_delete (GLib.SimpleAction action, GLib.Variant? param) {
            delete_selected_files ();
        }

        private void on_selection_action_restore (GLib.SimpleAction action, GLib.Variant? param) {
            unowned GLib.List<unowned GOF.File> selection = get_selected_files_for_transfer ();
            Marlin.restore_files_from_trash (selection, window);
        }

        private void on_selection_action_open_executable (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on selection action open");
            unowned GLib.List<unowned GOF.File> selection = get_files_for_action ();
            GOF.File file = selection.data as GOF.File;
            unowned Gdk.Screen screen = Eel.gtk_widget_get_screen (this);
            file.execute (screen, null, null);
        }

        private void on_selection_action_open_with_default (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on selection action open with default");
            activate_selected_items (Marlin.OpenFlag.DEFAULT);
        }

        private void on_selection_action_open_with_app (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on selection action open with app");
            var index = int.parse (param.get_string ());
            open_files_with (open_with_apps.nth_data ((uint)index), get_files_for_action ());
        }

        private void on_selection_action_open_with_other_app () {
//message ("on selection action open with other app");
            unowned GLib.List<unowned GOF.File> selection = get_files_for_action ();
            var dialog = new Gtk.AppChooserDialog (window, 0, selection.data.location);
            GOF.File file = selection.data as GOF.File;

            var check_default = new Gtk.CheckButton.with_label (_("Set as default"));
            dialog.get_content_area ().pack_start (check_default, false, false, 0);
            dialog.show_all ();

            int response = dialog.run ();
            if (response == Gtk.ResponseType.OK) {
                var app =dialog.get_app_info ();
                if (check_default.get_active ()) {
                    try {
                        app.set_as_default_for_type (file.get_ftype ());
                    }
                    catch (GLib.Error error) {
                        critical ("Could not set as default: %s", error.message);
                    }
                }
                open_files_with (app, selection);
            }
        }

        private void on_common_action_bookmark (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on selection bookmark");
            if (selected_files != null)
                window.sidebar.add_uri (selected_files.data.uri);
            else
                window.sidebar.add_uri (slot.directory.file.uri);
        }


                /** Background actions */

        private void change_state_show_hidden (GLib.SimpleAction action) {
            window.change_state_show_hidden (action);
        }

        private void on_background_action_new (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on background action new");
            switch (param.get_string ()) {
                case "FOLDER":
                    new_empty_folder ();
                    break;
                case "FILE":
                    new_empty_file ();
                    break;
                default:
                    break;
            }
        }

        private void on_background_action_create_from (GLib.SimpleAction action, GLib.Variant? param) {
            int index = int.parse (param.get_string ());
            create_from_template (templates.nth_data ((uint)index));
        }

        private void on_background_action_sort_by_changed (GLib.SimpleAction action, GLib.Variant? val) {
            string sort = val.get_string ();
            set_sort (sort, false);
        }
        private void on_background_action_reverse_changed (GLib.SimpleAction action, GLib.Variant? val) {
            set_sort (null, true);
        }

        private void set_sort (string? col_name, bool reverse) {
//message ("set sort");
            int sort_column_id;
            Gtk.SortType sort_order;
            if (model.get_sort_column_id (out sort_column_id, out sort_order)) {
                if (col_name != null)
                    sort_column_id = get_column_id_from_string (col_name);

                if (reverse) {
                    if (sort_order == Gtk.SortType.ASCENDING)
                        sort_order = Gtk.SortType.DESCENDING;
                    else
                        sort_order = Gtk.SortType.ASCENDING;
                }
                    
                model.set_sort_column_id (sort_column_id, sort_order);
            }
        }

        /** Common actions */

        private void on_common_action_open_in (GLib.SimpleAction action, GLib.Variant? param) {
//message ("on common action open in ");
            default_app = null;
            get_files_for_action ();

            switch (param.get_string ()) {
                case "TAB":
                    activate_selected_items (Marlin.OpenFlag.NEW_TAB);
                    break;
                case "WINDOW":
                    activate_selected_items (Marlin.OpenFlag.NEW_WINDOW);
                    break;
                case "TERMINAL":
                    open_selected_in_terminal ();
                    break;
                default:
                    break;
            }
        }

        private void open_selected_in_terminal () {
            var terminal = new GLib.DesktopAppInfo (Marlin.OPEN_IN_TERMINAL_DESKTOP_ID);
            if (terminal != null)
                open_files_with (terminal, selected_files);
        }

        private void on_common_action_properties (GLib.SimpleAction action, GLib.Variant? param) {
            new Marlin.View.PropertiesWindow (get_files_for_action (), this, window);
        }

        private void on_common_action_copy (GLib.SimpleAction action, GLib.Variant? param) {
            get_files_for_action ();
            unowned GLib.List<unowned GOF.File> selection = get_selected_files_for_transfer ();
            clipboard.copy_files (selection);
        }

        private void on_common_action_paste_into (GLib.SimpleAction action, GLib.Variant? param) {
            get_files_for_action ();
            var file = get_selected_files ().nth_data (0);
            if (file != null && file.is_folder ()) {
                prepare_to_select_added_files ();
                clipboard.paste_files (file.get_target_location (), this as Gtk.Widget, null);
            }
        }


        private void on_directory_file_added (GOF.Directory.Async dir, GOF.File file) {
//message ("on directory file added");
            add_file (file, dir);
        }

        private void on_directory_file_loaded (GOF.Directory.Async dir, GOF.File file) {
            select_added_files = false;
            add_file (file, dir);
        }

        private void on_directory_file_changed (GOF.Directory.Async dir, GOF.File file) {
            remove_marlin_icon_info_cache (file);
            model.file_changed (file, dir);
            /* 3rd parameter is for returned request id if required - we do not use it? */
            /* This is required if we need to dequeue the request */
            thumbnailer.queue_file (file, null, false);
        }

        private void on_directory_file_icon_changed (GOF.Directory.Async dir, GOF.File file) {
            model.file_changed (file, dir);
        }

        private void on_directory_file_deleted (GOF.Directory.Async dir, GOF.File file) {
            remove_marlin_icon_info_cache (file);
            model.remove_file (file, dir);
            if (file.is_folder ()) {
                var file_dir = GOF.Directory.Async.cache_lookup (file.location);
                if (file_dir != null) {
                    file_dir.purge_dir_from_cache ();
                    slot.folder_deleted (file, file_dir); /* Do not deal with mwcols directly */
                }
            }
        }

        private void  on_directory_done_loading (GOF.Directory.Async dir) {
//message ("DV  directory done loading %s", dir.file.uri);
            dir.file_loaded.disconnect (on_directory_file_loaded);
            in_trash = (dir.file.uri == Marlin.TRASH_URI); /* trash cannot be subdirectory */
            thaw_tree ();
            queue_draw ();
        }

        private void on_directory_thumbs_loaded (GOF.Directory.Async dir) {
//message ("on directory thumbs loaded");
            Marlin.IconInfo.infos_caches ();
        }

    /** Handle zoom level change */
        private void on_zoom_level_changed (Marlin.ZoomLevel zoom) {
//message ("DV on zoom level changed");
            model.set_property ("size", icon_size);
            zoom_level_changed ();
            if (get_realized ())
                load_thumbnails (slot.directory, zoom);
        }

    /** Handle Preference changes */
        private void on_show_hidden_files_changed (GLib.Object prefs, GLib.ParamSpec pspec) {
//message ("show_hidden files changed");
            bool show = (prefs as GOF.Preferences).show_hidden_files;
            if (!show) {
                block_model ();
                model.clear ();
            }

            directory_hidden_changed (slot.directory, show);
            if (loaded_subdirectories != null)
                loaded_subdirectories.@foreach ((dir) => {
                    directory_hidden_changed (dir, show);
                });

            if (!show)
                unblock_model ();

            action_set_state (background_actions, "show_hidden", show);
        }

        private void directory_hidden_changed (GOF.Directory.Async dir, bool show) {
//message ("directory hidden changed di %s", dir.file.uri);
            dir.file_loaded.connect (on_directory_file_loaded); /* disconnected by on_done_loading callback.*/
            if (show)
                dir.load_hiddens ();
            else
                dir.load ();
        }

        private void on_interpret_desktop_files_changed () {
            slot.directory.update_desktop_files ();
        }

    /** Handle popup menu events */
        private bool on_popup_menu () {
//message ("on popup menu");
            Gdk.Event event = Gtk.get_current_event ();
            show_or_queue_context_menu (event);
            return true;
        }

    /** Handle Button events */
        private bool on_button_release (Gdk.EventButton event) {
//message ("Directory on button release");
            /* Only active during drag timeout */
            cancel_drag_timer ();
            if (event.button == 3)
                show_context_menu (event);

            return false;
        }

        private bool on_button_press_event (Gdk.EventButton event) {
//message ("Directory view on button press event");
            /* Extra mouse button action: button8 = "Back" button9 = "Forward" */
            GLib.Action? action = null;
            GLib.SimpleActionGroup main_actions = window.get_action_group ();
            if (event.type == Gdk.EventType.BUTTON_PRESS) {
                if (event.button == 8)
                    action = main_actions.lookup_action ("Back");
                else if (event.button == 9)
                    action = main_actions.lookup_action ("Forward");

                if (action != null) {
                    action.activate (null);
                    return true;
                }
            }
            return false;
        }

/** Handle Motion events */
        private bool on_drag_timeout_motion_notify (Gdk.EventMotion event) {
//message ("on drag timeout motion notify");
            /* Only active during drag timeout */
            Gdk.DragContext context;
            var widget = get_real_view ();
            int x = (int)event.x;
            int y = (int)event.y;

            if (Gtk.drag_check_threshold (widget, drag_x, drag_y, x, y)) {
                cancel_drag_timer ();
                var target_list = new Gtk.TargetList (drag_targets);
                context = Gtk.drag_begin_with_coordinates (widget,
                                target_list,
                                Gdk.DragAction.ASK | file_drag_actions,
                                3,
                                (Gdk.Event) event,
                                 x, y);
                return true;
            } else
                return false;
        }

/** Handle TreeModel events */
        protected virtual void on_row_deleted (Gtk.TreePath path) {
//message ("on row deleted");
             GLib.List<Gtk.TreePath>? selected_paths = get_selected_paths ();
            selection_before_delete = null;

            /* Do nothing if the deleted row is not selected or there is more than one file selected */
            if (selected_paths == null ||
                selected_paths.length () != 1 ||
                selected_paths.find_custom (path, Gtk.TreePath.compare) == null)

                return;

            /* Create a copy the path (we're not allowed to modify it in this handler) */
            Gtk.TreePath path_copy = path.copy ();

            /* Remember the selected path so that it can be restored after the row has
             * been removed. If the first row is removed, select the first row after the
             * removal, if any other row is removed, select the row before that one */
            path_copy.prev ();
            selection_before_delete = path_copy.copy ();
        }

/** Handle clipboard signal */
        private void on_clipboard_changed () {
//message ("on clipboard changed");
            update_menu_actions ();
            /* show possible change in appearance of cut items */
            queue_draw ();
        }

/** Handle Selection changes */
        public void notify_selection_changed () {
//message ("notify selection changed calls update menu actions");
            selection_was_removed = false;
            if (!get_realized ()) {
//message ("not realized");
                return;
            }

            if (updates_frozen) {
//message ("updates frozen");
                return;
            }

            update_menu_actions ();
            window.selection_changed (get_selected_files ());
        }

    /** Handle size allocation event */
        private void on_size_allocate (Gtk.Allocation allocation) {
//message ("on size allocate");
            schedule_thumbnail_timeout ();
        }

/** DRAG AND DROP */

    /** Handle Drag source signals*/

        private void on_drag_begin (Gdk.DragContext context) {
//message ("on drag begin");
            drag_has_begun = true;
            /* Do we need to free the drag_file_list? */
            drag_file_list = get_selected_files_for_transfer ();
            if (drag_file_list == null)
                return;

            GOF.File file = drag_file_list.first ().data;
            /* TODO - get drag icon depending on view and zoom_level */
            if (file != null && file.pix != null)
                Gtk.drag_set_icon_pixbuf (context, file.pix, 0, 0);
            else
                Gtk.drag_set_icon_name (context, "stock-file", 0, 0);
        }

        private void on_drag_data_get (Gdk.DragContext context,
                                       Gtk.SelectionData selection_data,
                                       uint info,
                                       uint timestamp) {
//message ("on drag data get");
            GLib.StringBuilder sb = new GLib.StringBuilder ("");
            drag_file_list.@foreach ((file) => {
                sb.append (file.uri);
                sb.append ("\n");
            });

            selection_data.@set (selection_data.get_target (),
                                 8,
                                 sb.data);
//message ("leaving");
        }

        private void on_drag_data_delete (Gdk.DragContext context) {
//message ("on drag data delete");
            /* block real_view default handler because handled in on_drag_end */
            GLib.Signal.stop_emission_by_name (get_real_view (), "drag-data-delete");
        }

        private void on_drag_end (Gdk.DragContext context) {
            cancel_drag_scroll_timer ();
            drag_file_list = null;
            drop_target_file = null;
            current_suggested_action = Gdk.DragAction.DEFAULT;
            current_actions = Gdk.DragAction.DEFAULT;
            drag_has_begun = false;
            drop_occurred = false;
        }


/** Handle Drop target signals*/
        private bool on_drag_motion (Gdk.DragContext context,
                             int x,
                             int y,
                             uint timestamp) {
//message ("on drag motion");
            /* if we don't have drop data already ... */
            if (!drop_data_ready) {
                get_drop_data (context, x, y, timestamp);
            } else
                /* We have the drop data - check whether we can drop here*/
                check_destination_actions_and_target_file (context, x, y, timestamp);

            if (drag_scroll_timer_id == 0)
                start_drag_scroll_timer (context);

            return false;
        }

        private bool on_drag_drop (Gdk.DragContext context,
                                   int x,
                                   int y,
                                   uint timestamp) {
//message ("on drag drop");
            Gtk.TargetList list = null;
            string? uri = null;
            bool ok_to_drop = false;

            Gdk.Atom target = Gtk.drag_dest_find_target  (get_real_view (), context, list);
            if (target == Gdk.Atom.intern_static_string ("XdndDirectSave0")) {
                GOF.File? target_file = get_drop_target_file (x, y, null);
                if (target_file != null) {
                    /* get XdndDirectSave file name from DnD source window */
                    string? filename = dnd_handler.get_source_filename (context);
                    if (filename != null) {
                        /* Get uri of source file when dropped */
                        uri = target_file.get_target_location ().resolve_relative_path (filename).get_uri ();
                        /* Setup the XdndDirectSave property on the source window */
                        dnd_handler.set_source_uri (context, uri);
                        ok_to_drop = true;
                    } else
                        Eel.show_error_dialog (_("Cannot drop this file"), _("Invalid file name provided"), null);
                }                        
            } else
                ok_to_drop = (target != Gdk.Atom.NONE);

            if (ok_to_drop) {
                drop_occurred = true;
                /* request the drag data from the source (initiates
                 * saving in case of XdndDirectSave).*/
                Gtk.drag_get_data (get_real_view (), context, target, timestamp);
            
            }
            return ok_to_drop;
        }


        private void on_drag_data_received (Gdk.DragContext context,
                                            int x,
                                            int y,
                                            Gtk.SelectionData selection_data,
                                            uint info,
                                            uint timestamp
                                            ) {
//message ("drag data received");
            bool success = false;

            if (!drop_data_ready) {
                /* We don't have the drop data - extract uri list from selection data */
                string? text;
                if (dnd_handler.selection_data_is_uri_list (selection_data, info, out text)) {
                    drop_file_list = EelGFile.list_new_from_string (text);
                    drop_data_ready = true;
                }
            }

            if (drop_occurred) {
                drop_occurred = false;
                if (current_actions != Gdk.DragAction.DEFAULT) {
                    switch (info) {
                        case TargetType.XDND_DIRECT_SAVE0:
                            success = dnd_handler.handle_xdnddirectsave  (context, drop_target_file, selection_data);
                            break;

                        case TargetType.NETSCAPE_URL:
                            success = dnd_handler.handle_netscape_url  (context, drop_target_file, selection_data);
                            break;

                        case TargetType.TEXT_URI_LIST:
                            if ((current_actions & file_drag_actions) != 0) {
                                prepare_to_select_added_files ();
                                success = dnd_handler.handle_file_drag_actions  (get_real_view (), window, context, drop_target_file, drop_file_list, current_actions, current_suggested_action, timestamp);
                            }
                            break;
                        default:
                            break;
                    }
                }
                Gtk.drag_finish (context, success, false, timestamp);
                on_drag_leave (context, timestamp);
            }
        }

        private void on_drag_leave (Gdk.DragContext context, uint timestamp) {
//message ("on drag leave");
            /* reset the drop-file for the icon renderer */
            icon_renderer.set_property ("drop-file", GLib.Value (typeof (Object)));
            /* stop any running drag autoscroll timer */
            cancel_drag_scroll_timer ();
            /* disable the drop highlighting around the view */
            if (drop_highlight) {
                drop_highlight = false;
                queue_draw ();
            }
            /* reset the "drop data ready" status and free the URI list */
            if (drop_data_ready) {
                drop_file_list = null;
                drop_data_ready = false;
            }
            /* disable the highlighting of the items in the view */
            highlight_path (null);
        }

/** DnD helpers */

        private GOF.File? get_drop_target_file (int x, int y, out Gtk.TreePath? path_return) {
//message ("get drop target file x %i, y %i", x, y);
            Gtk.TreePath? path = get_path_at_pos (x, y);
            GOF.File? file = null;

            if (path != null) {
                file = model.file_for_path (path);
                if (file == null) {
                    /* must be on expanded empty folder, use the folder path instead */
                    Gtk.TreePath folder_path = path.copy ();
                    folder_path.up ();
                    file = model.file_for_path (folder_path);
                } else {
                    /* can only drop onto folders and executables */
                    if (!file.is_folder () && !file.is_executable ()) {
                        file = null;
                        path = null;
                    }
                }
            }

            if (path == null)
                /* drop to current folder instead */
                file = slot.directory.file;

            path_return = path;
            return file;
        }   

        private void get_drop_data (Gdk.DragContext context, int x, int y, uint timestamp) {
//message ("get_drop data - slot uri %s", slot.directory.file.uri);
            Gdk.DragAction action = Gdk.DragAction.DEFAULT;
            Gtk.TargetList? list = null; /* NOTE incorrect Gtk vapi file for this function */
            Gdk.Atom target = Gtk.drag_dest_find_target (get_real_view (), context, list);
            /* Check if we can handle it yet */
            if (target == Gdk.Atom.intern_static_string ("XdndDirectSave0") ||
                target == Gdk.Atom.intern_static_string ("_NETSCAPE_URL")) {

                /* Determine file at current position (if any) */
                Gtk.TreePath? path = null;
                GOF.File? file = get_drop_target_file (x, y, out path);

                if (file != null &&
                    file.is_folder () &&
                    file.is_writable ()) {
                    action = context.get_suggested_action ();
                }
            } else if (target != Gdk.Atom.NONE)
                /* request the drag data from the source */
                Gtk.drag_get_data (get_real_view (), context, target, timestamp); /* emits "drag_data_received" */

            /* tell Gdk whether we can drop here */
            Gdk.drag_status (context, action, timestamp);
        }

        private void check_destination_actions_and_target_file (Gdk.DragContext context, int x, int y, uint timestamp) {
//message ("get dest actions");
            Gtk.TreePath? path;
            GOF.File? file = get_drop_target_file (x, y, out path);
            string uri = file != null ? file.uri : "";
            string current_uri = drop_target_file != null ? drop_target_file.uri : "";
            if (uri != current_uri) {
                drop_target_file = file;
                current_actions = Gdk.DragAction.DEFAULT;
                current_suggested_action = Gdk.DragAction.DEFAULT;
                if (file != null) {
                    current_actions = file.accepts_drop (drop_file_list, context, out current_suggested_action);
                    highlight_drop_file (file, current_suggested_action, path);
                }
                Gdk.drag_status (context, current_suggested_action, timestamp);
            }
        }

        private void highlight_drop_file (GOF.File drop_file, Gdk.DragAction action, Gtk.TreePath? path) {
//message ("highlight dropfile");
            /* Set highlighting accordingly */
            bool can_drop = (action != Gdk.DragAction.DEFAULT);
            if (drop_highlight != can_drop) {
                drop_highlight = can_drop;
                queue_draw ();
            }

            /* Set the icon_renderer drop-file if there is an action */
            drop_file =  can_drop ? drop_file : null;
            icon_renderer.set_property ("drop-file", drop_file);

            highlight_path (can_drop ? path : null);
        }

/** MENU FUNCTIONS */

        /*
         * (derived from thunar: thunar_standard_view_queue_popup)
         * 
         * Schedules a context menu popup in response to
         * a right-click button event. Right-click events
         * need to be handled in a special way, as the
         * user may also start a drag using the right
         * mouse button and therefore this function
         * schedules a timer, which - once expired -
         * opens the context menu. If the user moves
         * the mouse prior to expiration, a right-click
         * drag (with #GDK_ACTION_ASK) will be started
         * instead.
        **/
        private void queue_context_menu (Gdk.Event event) {
//message ("queue context menu");
            if (drag_timer_id > 0) /* already queued */
                return;

            start_drag_timer (event);
        }

        protected void start_drag_timer (Gdk.Event event) {
//message ("start drag timer");
            connect_drag_motion_and_release_events ();
            /* Remember position of click */ 
            drag_x = (int)(event.button.x);
            drag_y = (int)(event.button.y);
            drag_timer_id = GLib.Timeout.add_full (GLib.Priority.LOW,
                                                   drag_delay,
                                                   () => {
//message ("drag time out");
                disconnect_drag_timeout_motion_and_release_events ();
                drag_timer_id = 0;
                show_context_menu (event);
                return false;
            });
        }

        protected void show_context_menu (Gdk.Event event) {
//message ("show context menu");
            /* select selection or background context menu */
            var builder = new Gtk.Builder.from_file (Config.UI_DIR + "directory_view_popup.ui");
            GLib.MenuModel? model;
            if (get_selected_files () != null) 
                model = build_menu_selection (ref builder, in_trash);
            else
                model = build_menu_background (ref builder, in_trash);

            if (model != null) {
                /* add any additional entries from plugins */
                var menu = new Gtk.Menu.from_model (model);
                plugins.hook_context_menu (menu as Gtk.Widget, get_selected_files ());
                menu.set_screen (null);
                menu.attach_to_widget (this, null);
                Eel.pop_up_context_menu (menu, Eel.DEFAULT_POPUP_MENU_DISPLACEMENT, Eel.DEFAULT_POPUP_MENU_DISPLACEMENT, (Gdk.EventButton) event);
            }
        }

        private GLib.MenuModel? build_menu_selection (ref Gtk.Builder builder, bool in_trash) {
//message ("build menu selection");
            GLib.Menu menu;
            if (in_trash)
                menu = builder.get_object ("popup-trash-selection") as GLib.Menu;
            else {
                menu = builder.get_object ("popup-selection") as GLib.Menu;
                menu.append_section (null, builder.get_object ("clipboard") as GLib.MenuModel);
                menu.append_section (null, build_menu_open ());
                if (common_actions.get_action_enabled ("open_in"))
                    menu.append_section (null, builder.get_object ("open-in") as GLib.MenuModel);

                if (common_actions.get_action_enabled ("bookmark"))
                    menu.append_section (null, builder.get_object ("bookmark") as GLib.MenuModel);
            }
            menu.append_section (null, builder.get_object ("properties") as GLib.MenuModel);
            return menu as MenuModel;
        }

        private GLib.MenuModel? build_menu_background (ref Gtk.Builder builder, bool in_trash) {
//message ("build menu background");
            if (in_trash)
                return null;

            var menu = builder.get_object ("popup-background") as GLib.Menu;

            menu.append_section (null, builder.get_object ("clipboard") as GLib.MenuModel);
            menu.append_section (null, builder.get_object ("open-in") as GLib.MenuModel);

            GLib.MenuModel? template_menu = build_menu_templates ();
            if (template_menu != null) {
                var new_menu = builder.get_object ("new") as GLib.Menu;
                new_menu.append_section (null, template_menu);
            }

            menu.append_section (null, builder.get_object ("sort-by") as GLib.MenuModel);

            if (common_actions.get_action_enabled ("bookmark"))
                menu.append_section (null, builder.get_object ("bookmark") as GLib.MenuModel);

            menu.append_section (null, builder.get_object ("properties") as GLib.MenuModel);
            return menu as MenuModel;
        }

        private GLib.MenuModel build_menu_open () {
//message ("build menu open");
            var menu = new GLib.Menu ();        
            string label = _("Invalid");
            var selection = selected_files.data;
            if (!selection.is_folder () && selection.is_executable ()) {
                    label = _("Run");
                    menu.append (label, "selection.open");
            } else if (default_app != null) {
                var app_name = default_app.get_display_name ();

                if (app_name != "Files") {
                    label = (_("Open with %s")).printf (app_name);
                    menu.append (label, "selection.open_with_default");
                }
            }

            GLib.MenuModel? app_submenu = build_submenu_open_with_applications ();
            if (app_submenu != null) {
                menu.append_submenu (_("Open with"), app_submenu);
            }

            return menu as MenuModel;
        }

        private GLib.MenuModel? build_submenu_open_with_applications () {
//message ("build submenu open with apps");
            unowned GLib.List<unowned GOF.File> selection = get_selected_files ();
            open_with_apps = Marlin.MimeActions.get_applications_for_files (selection);
            filter_default_app_from_open_with_apps ();
            filter_this_app_from_open_with_apps ();
            if (open_with_apps.length () == 0)
                return null;

            var apps_submenu = new GLib.Menu ();
            int index = -1;
            open_with_apps.@foreach ((app) => {
                var label = app.get_display_name ();
                if (label == "Files")
                    label = app.get_executable ();

                index++;
                apps_submenu.append (label, "selection.open_with_app::" + index.to_string ());
            });

            if (selection.length () == 1)
                apps_submenu.append (_("Other Application"), "selection.other_app");

            return apps_submenu as MenuModel;
        }

        private GLib.MenuModel? build_menu_templates () {
        /* TODO - Do just once when app starts or view created? */
//message ("build template menu");
            templates = null;
            load_templates_from_folder (GLib.File.new_for_path ("%s/Templates".printf (GLib.Environment.get_home_dir ())));
            if (templates.length () == 0)
                return null;

            var templates_menu = new GLib.Menu ();
            var templates_submenu = new GLib.Menu ();
            int index = 0;
            int count = 0;
            templates.@foreach ((template) => {
                var label = template.get_display_name ();
                if (!template.is_folder ()) {
                    templates_submenu.append (label, "background.create_from::" + index.to_string ());
                    count ++;
                } else {
                    var submenu = new GLib.MenuItem.submenu (label, templates_submenu);
                    templates_menu.append_item (submenu);
                    templates_submenu = new GLib.Menu ();
                }
                index++;
            });

            templates_menu.append_section (null, templates_submenu);

            if (count < 1)
                return null;
            else
                return templates_menu as MenuModel;
        }

        private void update_menu_actions () {
            if (updates_frozen)
                return;
//message ("update menu actions for slot %s", slot.directory.file.uri);
            unowned GLib.List<unowned GOF.File> selection = get_selected_files ();
            uint selection_count = selection.length ();
            bool more_than_one_selected = (selection_count > 1);
            bool single_folder = true; /* background is a folder */
            bool only_folders = selection_only_contains_folders (selection);

            if (selection_count > 0) {
                unowned GOF.File? file = selection.data;
                if (file != null) {
                    single_folder = (!more_than_one_selected && file.is_folder ());
                    update_default_app (selection);
                } else
                    critical ("File in selection is null");
            }

            update_paste_action_enabled (single_folder);
            update_select_all_action ();
            update_menu_actions_sort ();

            action_set_enabled (common_actions, "open_in", only_folders);
            action_set_enabled (selection_actions, "rename", selection_count == 1);
            action_set_enabled (selection_actions, "open", selection_count == 1);
            action_set_enabled (selection_actions, "cut", selection_count > 0);
            action_set_enabled (common_actions, "bookmark", !more_than_one_selected);
        }

        private void update_menu_actions_sort () {
            int sort_column_id;
            Gtk.SortType sort_order;
            if (model.get_sort_column_id (out sort_column_id, out sort_order)) {
                GLib.Variant val = new GLib.Variant.string (get_string_from_column_id (sort_column_id));
                action_set_state (background_actions, "sort_by", val);
                val = new GLib.Variant.boolean (sort_order == Gtk.SortType.DESCENDING);
                action_set_state (background_actions, "reverse", val);
            }
        }

        private void update_default_app (GLib.List<unowned GOF.File> selection) {
//message ("update default app");
            default_app = Marlin.MimeActions.get_default_application_for_files (selection);
        }

        private void update_paste_action_enabled (bool single_folder) {
//message ("update paste action enabled");

            if (clipboard != null && clipboard.get_can_paste ())
                action_set_enabled (common_actions, "paste_into", single_folder);
            else
                action_set_enabled (common_actions, "paste_into", false);
        }

        private void update_select_all_action () {
            action_set_enabled (window.win_actions, "select_all", !slot.directory.is_empty ());
        }

    /** Menu helpers */

        private void action_set_enabled (GLib.SimpleActionGroup? action_group, string name, bool enabled) {
            if (action_group != null) {
                GLib.SimpleAction? action = (action_group.lookup_action (name) as GLib.SimpleAction);
                if (action != null) {
                    action.set_enabled (enabled);
                    return;
                }
            }
            critical ("Action name not found: %s - cannot enable", name); 
        }
        private void action_set_state (GLib.SimpleActionGroup? action_group, string name, GLib.Variant val) {
            if (action_group != null) {
                GLib.SimpleAction? action = (action_group.lookup_action (name) as GLib.SimpleAction);
                if (action != null) {
//message ("action set state name %s, type %s", name, val.get_type_string ());
                    action.set_state (val);
                    return;
                }
            }
            critical ("Action name not found: %s - cannot set state", name); 
        }

        private void load_templates_from_folder (GLib.File template_folder) {
//message ("load templates from folder");
            GLib.List<GOF.File>? gof_file_list = null;
            GLib.List<GLib.File>? folder_list = null;

            GLib.FileEnumerator enumerator;
            try {
                enumerator = template_folder.enumerate_children (GLib.FileAttribute.STANDARD_NAME, GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                uint count = templates.length ();
                GLib.File location;
                GOF.File file;
                GLib.FileInfo? info = enumerator.next_file (null);
                while (count < MAX_TEMPLATES && (info != null)) {
                    location = template_folder.get_child (info.get_name ());
                    file = GOF.File.@get (location);
                    file.ensure_query_info ();
                    if (file.is_folder ()) {
                        folder_list.prepend (location);
                    } else {
                        gof_file_list.prepend (file);
                        count ++;
                    }
                    info = enumerator.next_file (null);
                }
            } catch (GLib.Error error) {
                return;
            }

            if (gof_file_list.length () > 0) {
                gof_file_list.sort (GOF.File.compare_by_display_name);
                templates.concat (gof_file_list.copy ());
                GOF.File dir = GOF.File.@get (template_folder);
                dir.ensure_query_info ();
                templates.append (dir);
            }



            if (folder_list.length () > 0) {
                /* recursively load templates from subdirectories */
                folder_list.@foreach ((folder) => {
                    load_templates_from_folder (folder);
                });
            }
        }

        private void filter_this_app_from_open_with_apps () {
//message ("filter this app");
            string? exec_name;
            unowned GLib.List<AppInfo> l = open_with_apps;
            while (l != null) {
                exec_name = l.data.get_executable ();
                if (exec_name != null && (exec_name == APP_NAME || exec_name == TERMINAL_NAME)) {
                    open_with_apps.delete_link (l);
                    break;
                }
                l = l.next;
            }
        }

        private void filter_default_app_from_open_with_apps () {
//message ("filter default app");
            if (default_app == null)
                return;

            string? id1, id2;
            id2 = default_app.get_id ();
            if (id2 != null) {
                unowned GLib.List<AppInfo> l = open_with_apps;
                while (l != null) {
                    id1 = l.data.get_id ();
                    if (id1 != null && id1 == id2) {
                        open_with_apps.delete_link (l);
                        break;
                    }
                    l = l.next;
                }
            }
        }

        /** Menu action functions */

        private void create_from_template (GOF.File template) {
            Marlin.FileOperations.new_file_from_template (this,
                                                          null,
                                                          slot.location,
                                                          //slot.directory.location,
                                                          (_("Untitled %s")).printf (template.get_display_name ()),
                                                          template.location,
                                                          (Marlin.CreateCallback?) create_file_done,
                                                          this);
        }

        private void open_files_with (GLib.AppInfo app, GLib.List<unowned GOF.File> files) {
            GOF.File.launch_files (files, get_screen (), app);
        }


/** Thumbnail handling */
        private void schedule_thumbnail_timeout () {
            /* delay creating the idle until the view has finished loading.
             * this is done because we only can tell the visible range reliably after
             * all items have been added and we've perhaps scrolled to the file remembered
             * the last time */
            if (thumbnail_source_id != 0 || slot.directory == null)
                return;

            cancel_thumbnailing ();
            thumbnail_source_id = GLib.Timeout.add (175, () => {
                if (slot.directory.is_loading ())
                    return true;

                /* compute visible item range */
                Gtk.TreePath start_path, end_path, path;
                Gtk.TreeIter iter;
                bool valid_iter;
                GOF.File file;
                GLib.List<unowned GOF.File> visible_files = null;
                if (get_visible_range (out start_path, out end_path)) {
                    /* iterate over the range to collect all files */
                    valid_iter = model.get_iter (out iter, start_path);
                    while (valid_iter) {
                        file = model.file_for_iter (iter);
                        /* only ask thumbnails once per file */
                        if (file != null && file.flags == 0)
                            visible_files.prepend (file);

                        /* check if we've reached the end of the visible range */
                        path = model.get_path (iter);
                        if (path.compare (end_path) != 0)
                            valid_iter = model.iter_next (ref iter);
                        else
                            valid_iter = false;
                    }
                }

                if (visible_files != null)
                    thumbnailer.queue_files (visible_files, out thumbnail_request, false);

                thumbnail_source_id = 0;
                return false;
            });
        }


/** HELPER AND CONVENIENCE FUNCTIONS */

        protected void block_model () {
//message ("block model");
            model.row_deleted.disconnect (on_row_deleted);
            model.row_deleted.disconnect (after_restore_selection);
            updates_frozen = true;
        }

        protected void unblock_model () {
//message ("unblock model");
            model.row_deleted.connect (on_row_deleted);
            model.row_deleted.connect (after_restore_selection);
            updates_frozen = false;
        }

        private void load_thumbnails (GOF.Directory.Async dir, Marlin.ZoomLevel zoom) {
//message ("DV load thumbnails");
            /* Async function checks dir is not loading */
            dir.queue_load_thumbnails (Marlin.zoom_level_to_icon_size (zoom));
        }

        private Gtk.Widget? get_real_view () {
            return (this as Gtk.Bin).get_child ();
        }

        private void connect_drag_motion_and_release_events () {
//message ("connect motion and release events");
            var real_view = get_real_view ();
            real_view.button_release_event.connect (on_button_release);
            real_view.motion_notify_event.connect (on_drag_timeout_motion_notify);
        }

        private void disconnect_drag_timeout_motion_and_release_events () {
//message ("disconnect motion and release events");
            var real_view = get_real_view ();
            real_view.button_release_event.disconnect (on_button_release);
            real_view.motion_notify_event.disconnect (on_drag_timeout_motion_notify);
        }

        private void start_drag_scroll_timer (Gdk.DragContext context) {
            drag_scroll_timer_id = GLib.Timeout.add_full (GLib.Priority.LOW,
                                                          50,
                                                          () => {
                Gtk.Widget widget = (this as Gtk.Bin).get_child ();
                Gdk.Device pointer = context.get_device ();
                Gdk.Window window = widget.get_window ();
                int x, y, w, h;

                window.get_device_position (pointer, out x, out y, null);
                window.get_geometry (null, null, out w, out h);

                scroll_if_near_edge (y, h, 20, get_vadjustment ());
                scroll_if_near_edge (x, w, 20, get_hadjustment ());
                return true;
            });
        }

        private void scroll_if_near_edge (int pos, int dim, int threshold, Gtk.Adjustment adj) {
                /* check if we are near the edge */
                int band = 2 * threshold;
                int offset = pos - band;
                if (offset > 0)
                    offset = int.max (band - (dim - pos), 0);

                if (offset != 0) {
                    /* change the adjustment appropriately */
                    var val = adj.get_value ();
                    var lower = adj.get_lower ();
                    var upper = adj.get_upper ();
                    var page = adj.get_page_size ();

                    val = (val + 2 * offset).clamp (lower, upper - page);
                    adj.set_value (val);
                }
        }

        private void prepare_to_select_added_files () {
//message ("prepare to add selected files");
            if (selected_files != null)
                unselect_all ();

            select_added_files = true;
        }

        private void remove_marlin_icon_info_cache (GOF.File file) {
             string? path = file.get_thumbnail_path ();
            if (path != null) {
                Marlin.IconSize s;
                for (int z = Marlin.ZoomLevel.SMALLEST;
                     z <= Marlin.ZoomLevel.LARGEST;
                     z++) {
                    s = Marlin.zoom_level_to_icon_size ((Marlin.ZoomLevel)z);
                    Marlin.IconInfo.remove_cache (path, s);
                }
            }
        }

        private unowned GLib.List<unowned GOF.File> get_files_for_action () {
            if (selected_files == null)
                selected_files.prepend (slot.directory.file);

            return selected_files;
        }

        protected void on_view_items_activated () {
//message ("on view items activated");
            activate_selected_items (Marlin.OpenFlag.DEFAULT);
        }

        protected virtual void on_view_selection_changed () {
//message ("on tree selection changed");
            update_selected_files ();
            if (updates_frozen)
                return;

            notify_selection_changed ();
        }

        /* Was key_press_call_back */
        protected virtual bool on_view_key_press_event (Gdk.EventKey event) {
//message ("on view key_press_event");
            bool control_pressed = ((event.state & Gdk.ModifierType.CONTROL_MASK) != 0);
            bool shift_pressed = ((event.state & Gdk.ModifierType.SHIFT_MASK) != 0);

            switch (event.keyval) {
                case Gdk.Key.F10:
                    if (control_pressed) {
                        show_or_queue_context_menu (event);
                        return true;
                    } else
                        return false;

                case Gdk.Key.space:
                    if (!control_pressed && view_has_focus ()) {
                        if (shift_pressed)
                            activate_selected_items (Marlin.OpenFlag.NEW_TAB);
                        else
                            preview_selected_items ();

                        return true;
                    } else
                        return false;

                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    if (shift_pressed)
                        activate_selected_items (Marlin.OpenFlag.NEW_TAB);
                    else
                         activate_selected_items (Marlin.OpenFlag.DEFAULT);

                    return true;

                case Gdk.Key.T:
                    if (control_pressed && shift_pressed)
                        open_selected_in_terminal ();
                    break;

                case Gdk.Key.N:
                    if (control_pressed && shift_pressed)
                        activate_selected_items (Marlin.OpenFlag.NEW_TAB);
                    break;

                default:
                    break;
            }
            return false;
        }

        protected bool on_motion_notify_event (Gdk.EventMotion event) {
//message ("on_motion_notify event");
            int x, y, mask;
            /* We need to use the device position for rubberbanding to work properly in ListView */
            get_window ().get_device_position (event.get_device (), out x, out y, out mask);
            var path = get_path_at_pos (x, y);

            if ((path != null && hover_path == null) ||
                (path == null && hover_path != null) ||
                (path != null && hover_path != null && path.compare (hover_path) != 0)) {

                GOF.File? file = path != null ? model.file_for_path (path) : null;
                window.item_hovered (file);
                hover_path = path;
            }

            return false;
        }

        protected bool on_leave_notify_event (Gdk.EventCrossing event) {
            window.item_hovered (null); /* Cause OverLay to disappear */
            return false;
        }

        protected virtual bool on_scroll_event (Gdk.EventScroll event) {
            if ((event.state & Gdk.ModifierType.CONTROL_MASK) == 0) {
                double increment = 0.0;
                switch (event.direction) {
                    case Gdk.ScrollDirection.LEFT:
                        increment = 5.0;
                        break;
                    case Gdk.ScrollDirection.RIGHT:
                        increment = -5.0;
                        break;
                    case Gdk.ScrollDirection.SMOOTH:
                        double delta_x;
                        event.get_scroll_deltas (out delta_x, null);
                        increment = delta_x * 10.0;
                        break;
                    default:
                        break;
                }
                if (increment != 0.0)
                    slot.horizontal_scroll_event (increment);
            }
            return handle_scroll_event (event);
        }

    /** name renderer signals */
        protected void on_name_editing_started (Gtk.CellEditable editable, string path) {
//message ("on name editing started");
            renaming = true;
            freeze_updates ();
            editable_widget = editable as Gtk.Entry;
            original_name = editable_widget.get_text ().dup ();
            editable_widget.focus_out_event.connect ((event) => {
                on_name_editing_canceled ();
                return false;
            });
        }

        protected void on_name_editing_canceled () {
//message ("on name editing canceled");
                if (!renaming)
                    return;

                editable_widget = null;
                renaming = false;
                unfreeze_updates ();
                
        }

        protected void on_name_edited (string path_string, string new_name) {
            /* Don't allow a rename with an empty string. Revert to original
             * without notifying the user. */
//message ("on name edited");

            on_name_editing_canceled ();
            if (new_name != "") {
                /* Validate filename before trying to rename the file */
                try {
                    Filename.from_uri ("file:///" + Uri.escape_string (new_name));
                } catch (GLib.ConvertError e) {
                    var dialog = new Gtk.MessageDialog ((Gtk.Window)window, Gtk.DialogFlags.DESTROY_WITH_PARENT, Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE, _("%s is not a valid file name"), new_name);
                    dialog.run ();
                    dialog.destroy ();
                    return;
                }

                var path = new Gtk.TreePath.from_string (path_string);
                Gtk.TreeIter? iter = null;
                model.get_iter (out iter, path);

                GOF.File? file = null;
                model.@get (iter,
                            FM.ListModel.ColumnID.FILE_COLUMN, out file);

                /* Only rename if name actually changed */
                if (!(new_name == original_name)) {
                    file.rename (new_name, (file, result_location, error) => {
                        /* FIXME Cannot access calling environment within this closure for some reason
                         * so cannot display dialog now*/
                        if (error != null)
                            warning ("Rename Error:  %s", error.message);
                    });
                }
            }
        }

       
        public virtual bool on_view_draw (Cairo.Context cr) {
//message ("DV on view draw, tree is loading %s, empty is %s", is_loading ? "true" : "false", slot.directory.is_empty () ? "true" : "false");
            /* If folder is empty, draw the empty message in the middle of the view
             * otherwise pass on event */
            if (is_loading || slot.directory.is_empty () || slot.directory.permission_denied) {
                Pango.Layout layout = create_pango_layout (null);
                if (slot.directory.is_empty ())
                    layout.set_markup (slot.empty_message, -1);
                else if (slot.directory.permission_denied) {
                    layout.set_markup (slot.denied_message, -1);
                } else 
                    layout.set_markup (slot.loading_message, -1);

                Pango.Rectangle? extents = null;
                layout.get_extents (null, out extents);

                double width = Pango.units_to_double (extents.width);
                double height = Pango.units_to_double (extents.height);

                double x = (double) get_allocated_width () / 2 - width / 2;
                double y = (double) get_allocated_height () / 2 - height / 2;
                get_style_context ().render_layout (cr, x, y, layout);
                return true;
            }
            return false;
        }

        protected virtual bool handle_primary_button_click (Gdk.EventButton event, Gtk.TreePath? path, bool on_icon) {
//message ("DV handle primary button");
            bool single_click_mode = Preferences.settings.get_boolean ("single-click");
            bool double_click_event = (event.type == Gdk.EventType.@2BUTTON_PRESS);
            if (on_icon && (single_click_mode || double_click_event )) {
                on_view_items_activated ();
                return true;
            } else
                return false; /* required for row expanders to work */
        }

        protected bool handle_secondary_button_click (Gdk.EventButton event) {
//message ("DV handle secondary button");
            show_or_queue_context_menu (event);
            return true;
        }

        protected void block_drag_and_drop () {
//message ("block_drag_and_drop");
            drag_data = view.get_data ("gtk-site-data");
            GLib.SignalHandler.block_matched (view, GLib.SignalMatchType.DATA, 0, 0,  null, null, drag_data);
            dnd_disabled = true;
            if (view is Gtk.TreeView)
                (view as Gtk.TreeView).set_rubber_banding (true);
        }

        protected void unblock_drag_and_drop () {
//message ("unblock_drag_and_drop");
            drag_data = view.get_data ("gtk-site-data");
            GLib.SignalHandler.unblock_matched (view, GLib.SignalMatchType.DATA, 0, 0,  null, null, drag_data);
            dnd_disabled = false;
        }

        protected virtual bool on_view_button_press_event (Gdk.EventButton event) {
//message ("DV view button press");
            grab_focus (); /* cancels any renaming */
            slot.active ();
            Gtk.TreePath? path = null;
            bool on_blank, on_icon, on_helper, on_name;
            get_event_position_info ((int)event.x, (int)event.y, out path,  out on_name, out on_blank, out on_icon, out on_helper);
            bool no_mods = (event.state & Gtk.accelerator_get_default_mod_mask ()) == 0;
            bool path_selected = (path != null ? path_is_selected (path) : false);

            if (!no_mods)
                return false;

            if (on_blank || (path != null && !path_selected && !on_helper)) {
                unselect_all ();
                if (!on_blank)
                    select_path (path);
            }

            bool result = true;
            switch (event.button) {
                case Gdk.BUTTON_PRIMARY:
                    if (on_blank) {
                        block_drag_and_drop ();  /* allow rubber banding */
                        return false;
                    } else if (on_helper) {
                        if (path_selected)
                            unselect_path (path);
                        else
                            select_path (path);
                    } else  if (on_name)
                        rename_file (selected_files.data); 
                    else
                        result = handle_primary_button_click (event, path, on_icon);

                    break;

                case Gdk.BUTTON_MIDDLE:
                    if (!on_blank)
                        activate_selected_items (Marlin.OpenFlag.NEW_TAB);

                    break;

                case Gdk.BUTTON_SECONDARY:
                    result = handle_secondary_button_click (event);
                    break;

                default:
                    result = handle_default_button_click ();
                    break;
            }
            return result;
        }

        protected virtual bool on_view_button_release_event (Gdk.EventButton event) {
//message ("DV button release");
            if (dnd_disabled)
                unblock_drag_and_drop ();

            return false;
        }

        public virtual void zoom_level_changed () {
            icon_renderer.set_property ("zoom-level", zoom_level);
            icon_renderer.set_property ("size", icon_size);
            helpers_shown = (zoom_level >= Marlin.ZoomLevel.NORMAL);
            icon_renderer.set_property ("selection-helpers", helpers_shown); /* TODO What is suitable minimum size? */
            
        }

        public void start_renaming_file (GOF.File file, bool preselect_whole_name) {
//message ("DV start renaming file");
            /* Select whole name if we are in renaming mode already */
            if (name_column != null && editable_widget != null) {
                editable_widget.select_region (0, -1);
                return;
            }

            Gtk.TreeIter? iter = null;
            if (!model.get_first_iter_for_file (file, out iter)) {
                critical ("Failed to find rename file in model");
                return;
            }

            /* Freeze updates to the view to prevent losing rename focus when the tree view updates */
            freeze_updates ();

            Gtk.TreePath path = model.get_path (iter);
            /* set cursor_on_cell also triggers editing-started, where we save the editable widget */
            set_cursor_on_cell (path, name_column, name_renderer, true, false);

            int start_offset= 0, end_offset = -1;
            if (editable_widget != null) {
                Marlin.get_rename_region (original_name, out start_offset, out end_offset, preselect_whole_name);
                editable_widget.select_region (start_offset, end_offset);
            }
        }

        protected string get_string_from_column_id (int id) {
            switch (id) {
            case FM.ListModel.ColumnID.FILENAME:
                return "name";
            case FM.ListModel.ColumnID.SIZE:
                return "size";
            case FM.ListModel.ColumnID.TYPE:
                return "type";
            case FM.ListModel.ColumnID.MODIFIED:
                return "modified";
            default:
                warning ("column id not recognised - using 'name'");
                return "name";
            }
        }
        protected int get_column_id_from_string (string col_name) {
            switch (col_name) {
            case "name":
                return FM.ListModel.ColumnID.FILENAME;
            case "size":
                return FM.ListModel.ColumnID.SIZE;
            case "type":
                return FM.ListModel.ColumnID.TYPE;
            case "modified":
                return FM.ListModel.ColumnID.MODIFIED;
            default:
                warning ("column name not recognised - using FILENAME");
                return FM.ListModel.ColumnID.FILENAME;
            }
        }

        protected void on_sort_column_changed () {
//message ("on_sort_column_changed");
            int sort_column_id;
            Gtk.SortType sort_order;
            if (!model.get_sort_column_id (out sort_column_id, out sort_order))
                return;

            var info = new GLib.FileInfo ();
            info.set_attribute_string ("metadata::marlin-sort-column-id",
                                       get_string_from_column_id (sort_column_id));
            info.set_attribute_string ("metadata::marlin-sort-reversed",
                                       (sort_order == Gtk.SortType.DESCENDING ? "true" : "false"));

            var dir = slot.directory;
            dir.file.sort_column_id = sort_column_id;
            dir.file.sort_order = sort_order;

            dir.location.set_attributes_async.begin (info,
                                               GLib.FileQueryInfoFlags.NONE,
                                               GLib.Priority.DEFAULT,
                                               null,
                                               (obj, res) => {
                try {
                    GLib.FileInfo inf;
                    dir.location.set_attributes_async.end (res, out inf); 
                } catch (GLib.Error e) {
                    warning ("Could not set file attributes - %s", e.message);
                }
            });

            update_menu_actions_sort ();
        }

/** Virtual methods - may be overridden*/
        public virtual void sync_selection () {}
        protected virtual void add_subdirectory (GOF.Directory.Async dir) {}
        protected virtual void remove_subdirectory (GOF.Directory.Async dir) {}
        public virtual void highlight_path (Gtk.TreePath? path) {}
        protected virtual bool handle_default_button_click () {return false;}
        protected virtual void freeze_tree () {is_loading = true;}
        protected virtual void thaw_tree () {is_loading = false;}

/** Abstract methods - must be overridden*/
        public abstract GLib.List<Gtk.TreePath> get_selected_paths () ;
        public abstract Gtk.TreePath? get_path_at_pos (int x, int y);
        public abstract void select_all ();
        public abstract void unselect_all ();
        public abstract void select_path (Gtk.TreePath? path);
        public abstract void unselect_path (Gtk.TreePath? path);
        public abstract bool path_is_selected (Gtk.TreePath? path);
        public abstract bool get_visible_range (out Gtk.TreePath? start_path, out Gtk.TreePath? end_path);
        protected abstract Gtk.Widget? create_view ();
        protected abstract Marlin.ZoomLevel get_set_up_zoom_level ();
        protected abstract Marlin.ZoomLevel get_normal_zoom_level ();
        protected abstract bool view_has_focus ();
        protected abstract void update_selected_files ();
        protected abstract void get_event_position_info (int x, int y, out Gtk.TreePath? path, out bool on_name, out bool on_blank, out bool on_icon, out bool on_helper);
        protected abstract void scroll_to_cell (Gtk.TreePath? path, Gtk.TreeViewColumn? col, bool scroll_to_top);
        protected abstract void set_cursor_on_cell (Gtk.TreePath path, Gtk.TreeViewColumn? col, Gtk.CellRenderer renderer, bool start_editing, bool scroll_to_top);
        public abstract void set_cursor (Gtk.TreePath? path, bool start_editing, bool select, bool scroll_to_top);

/** Unimplemented methods
 *  fm_directory_view_parent_set ()  - purpose unclear
*/ 
    }
}

